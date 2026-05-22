"""讲题 / 多 Agent 追问的 LLM 剧本生成服务。

设计要点：

- **单大模型单角色剧本**：用同一次 LLM 调用让 DeepSeek 扮演小明 / 大雄 / 班长
  中的**恰好 1 个**角色，避免多角色同轮发言混乱。李老师已拆到独立 `teacher_agent`，
  仅在学生主动请求「提示」时调用。
- **强 Schema 防御**：System Prompt 限定「只输出 JSON」、`response_format=json_object`
  双保险；解析时还要再做 markdown 去壳 + 字段白名单校验。
- **highlightStepIds 必须命中真实 stepId**：模型最爱编造 `step_99`，路由层会把
  真实白名单注入 Prompt，service 还会再过滤一次，命中不到的直接落回画板首步。
- **失败显式暴露**：DeepSeek 未配置、超时、返回非 JSON 或结构不合规时直接抛错；
  上层返回 HTTP 502 或 WebSocket error，让调试时能看到真实故障。
- **不持有路由层依赖**：本模块只产出 `dict`（与 Pydantic schema 对齐的字段），
  由 `routers/lecture.py` 负责套上 `LectureSubmitResponse`。这样 service 既可
  被路由调用，也方便后续单测。
- **多轮上下文**：`generate_lecture_turns(...)` 接收 `round_index` 与 `history`。
  Prompt 用最近 6 条历史让 LLM 评估学生当前输入是
  「在回答上一轮同伴追问」还是「重新讲一遍」。同伴 Agent 只产出追问，
  不再决定讨论是否结束（收束由用户侧「我懂了」触发，见产品规划）。
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any, Literal

from app.config import Config
from app.services.kimi import DEEPSEEK_THINKING_DISABLED, deepseek_client
from app.services import knowledge_index
from app.services.peer_personas import build_lecture_director_system_prompt

logger = logging.getLogger(__name__)


class LectureAgentError(RuntimeError):
    """Raised when the LLM lecture agent cannot produce a valid turn."""


_LECTURE_MODEL = Config.DEEPSEEK_MODEL
_LECTURE_TEMPERATURE = 0.4
_LECTURE_EXTRA_BODY: dict[str, Any] = DEEPSEEK_THINKING_DISABLED

# 非实时 `/lecture/submit` 仍需要等待完整 JSON；实时讲题走
# `lecture_agent_stream.py`，首 token 超过 2 秒会直接报错。
_LLM_TIMEOUT_SECONDS = 6.0


# ---------------------------------------------------------------------------
# 常量 & 角色映射
# ---------------------------------------------------------------------------


_ALLOWED_ROLES: tuple[str, ...] = ("xiaoming", "daxiong", "monitor")
_PEER_ROLES: tuple[str, ...] = _ALLOWED_ROLES
_ALLOWED_STATUS: tuple[str, ...] = ("needs_explanation", "completed")
_ALLOWED_DELTA: tuple[int, ...] = (-1, 0, 1)

# history 项里允许的 role。`student` / `system` 不在 LLM 输出
# 白名单内（不允许 LLM 扮演「学生」），但**作为输入历史**它们是合法来源。
_HISTORY_ROLES: tuple[str, ...] = (
    "student",
    "xiaoming",
    "daxiong",
    "monitor",
    "teacher",
    "system",
)

# 单次请求里 history 只取最近 N 条，避免 Prompt 暴涨；前端也建议只送最近
# 6-10 条。这里再做一次硬截断，防御前端实现走样。
_HISTORY_KEEP_LAST = 6

_DEFAULT_DISPLAY_NAME: dict[str, str] = {
    "xiaoming": "小明",
    "daxiong": "大雄",
    "monitor": "班长",
    "teacher": "李老师",
    "student": "我",
    "system": "系统",
}

# 单条发言文本上限（中文为主，留点余量给 LaTeX）。
_MAX_TEXT_LEN = 220

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"


def _load_section_titles() -> dict[str, str]:
    try:
        raw = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        logger.warning("[lecture-agent] curriculum titles unavailable: %s", e)
        return {}
    titles: dict[str, str] = {}
    for book in raw.get("books", []) if isinstance(raw, dict) else []:
        if not isinstance(book, dict):
            continue
        book_label = str(book.get("label") or "").strip()
        for chapter in book.get("chapters", []) or []:
            if not isinstance(chapter, dict):
                continue
            chapter_label = str(chapter.get("label") or "").strip()
            for section in chapter.get("sections", []) or []:
                if not isinstance(section, dict):
                    continue
                section_id = str(section.get("id") or "").strip()
                label = str(section.get("label") or section.get("title") or "").strip()
                if section_id:
                    titles[section_id] = " · ".join(
                        part for part in (book_label, chapter_label, label) if part
                    )
    return titles


_SECTION_TITLE: dict[str, str] = _load_section_titles()


_SYSTEM_PROMPT = build_lecture_director_system_prompt()


# ---------------------------------------------------------------------------
# Prompt 构造
# ---------------------------------------------------------------------------


def _sanitize_history(
    history: list[dict[str, Any]] | None,
) -> list[dict[str, Any]]:
    """把前端传来的 history 清洗一遍：

    - 丢掉非 dict 项与 role 不合法（不在 `_HISTORY_ROLES`）的项；
    - text 留 trim 后非空的；
    - 仅保留最近 `_HISTORY_KEEP_LAST` 条。

    任何异常都按「忽略本条」处理，绝不抛出，避免 history 缺失或格式异常
    直接打断讲题。
    """

    if not history:
        return []

    cleaned: list[dict[str, Any]] = []
    for item in history:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        if role not in _HISTORY_ROLES:
            continue
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        display = str(item.get("displayName") or item.get("display_name") or "").strip()
        if not display:
            display = _DEFAULT_DISPLAY_NAME.get(role, role)
        highlight_raw = (
            item.get("highlightStepIds") or item.get("highlight_step_ids") or []
        )
        if not isinstance(highlight_raw, list):
            highlight_raw = []
        highlight = [str(x).strip() for x in highlight_raw if str(x).strip()]
        cleaned.append(
            {
                "role": role,
                "display_name": display,
                "text": text,
                "highlight_step_ids": highlight,
            }
        )

    if len(cleaned) > _HISTORY_KEEP_LAST:
        cleaned = cleaned[-_HISTORY_KEEP_LAST:]
    return cleaned


def _last_peer_followup(history: list[dict[str, Any]]) -> dict[str, Any] | None:
    """从已清洗的 history 中找到「最近一条同伴追问」（不含李老师提示）。"""

    for item in reversed(history):
        if item["role"] in _PEER_ROLES:
            return item
    return None


def _build_user_prompt(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
    history: list[dict[str, Any]],
    purpose: Literal["lecture", "peer_assessment", "teacher"] = "lecture",
) -> str:
    """把请求里学生这边的所有上下文拼成一段紧凑的 user 提示。

    `studentSpeechText` 与 `steps[*].plainText / latex` 是学生侧语义证据。
    这里把它们清楚标成「学生自己说的话 / 学生自己写的步骤说明」，让 LLM
    优先围绕学生表达追问。

    对话历史段让 LLM 明确知道「学生这次到底是在回答上一轮的哪一个 AI 追问」，
    从而避免每轮都问同样的问题、能在合适时机切到 `status: completed`。
    """

    section_title = _SECTION_TITLE.get(section_id, section_id)

    lines: list[str] = []
    lines.append(f"【当前小节】{section_title}（sectionId={section_id}）")
    lines.append(f"【当前讲题轮次】{round_index}")
    lines.append(f"【题目 ID】{question_id}")
    lines.append(f"【题面】{question_prompt or '（题面未提供）'}")
    knowledge_context = knowledge_index.prompt_context(
        section_id=section_id,
        question_prompt=question_prompt,
        top_k=3,
    )
    if knowledge_context:
        lines.append("")
        lines.append(knowledge_context)
    speech = (student_speech_text or "").strip()
    has_step_text = any(
        (s.get("latex") or "").strip()
        or (s.get("plainText") or s.get("plain_text") or "").strip()
        for s in steps
    )
    if speech:
        lines.append(f'【学生口述（仅麦克风语音转写，不含白板文字）】"{speech}"')
    else:
        lines.append("【学生口述】（本轮学生没有有效语音转写；不要假装学生说过什么）")
    lines.append("")
    lines.append(
        "【学生白板步骤】下列 plainText / LaTeX 来自学生手敲说明或真实 OCR；"
        "**不是**语音口述，也**不是**题目自带的 referenceSteps 解题框架。"
        "描述时用「你写的」「白板上」；只有【学生口述】区块才能用「你说」。"
        "若某步只有笔画数、无文字/LaTeX，只能说「这一步有手写」，"
        "**禁止**猜测具体算式或把框架标签当成学生写的内容："
    )
    lines.append("按提交顺序，每行一条：")
    if not steps:
        lines.append("- （学生未写任何步骤）")
    else:
        for s in steps:
            sid = s.get("stepId") or s.get("step_id") or ""
            latex = (s.get("latex") or "").strip()
            plain = (s.get("plainText") or s.get("plain_text") or "").strip()
            strokes = s.get("strokeCount") or s.get("stroke_count") or 0
            descr_bits: list[str] = []
            if plain:
                descr_bits.append(f'步骤说明="{plain}"')
            if latex:
                descr_bits.append(f"步骤 LaTeX=`{latex}`")
            if not plain and not latex:
                descr_bits.append(
                    "（仅有手写笔画，无文字/OCR；禁止猜测具体写了什么）"
                )
            descr_bits.append(f"笔画数={strokes}")
            lines.append(f"- {sid}: " + "; ".join(descr_bits))

    lines.append("")
    lines.append(
        "【允许引用的 stepId 白名单】只能从下列 ID 中挑选，"
        "不允许编造任何不在该列表中的 stepId："
    )
    lines.append("- " + (", ".join(allowed_step_ids) if allowed_step_ids else "（空）"))

    lines.append("")
    last_followup = _last_peer_followup(history)
    if history:
        lines.append("【上一轮追问与回答历史】（按时间从早到晚，仅本题内最近若干条）")
        for h in history:
            role = h["role"]
            display = h["display_name"]
            text = h["text"].replace("\n", " ").strip()
            highlight = h.get("highlight_step_ids") or []
            highlight_part = (
                f"（关联步骤：{', '.join(highlight)}）" if highlight else ""
            )
            tag = "学生" if role == "student" else f"AI:{role}"
            lines.append(f'- [{tag} · {display}] "{text}"{highlight_part}')
        if last_followup is not None and purpose == "lecture":
            lines.append("")
            lines.append(
                f'重要：上一轮同伴（{last_followup["display_name"]}，role={last_followup["role"]}）'
                f'追问的是 "{last_followup["text"]}"。'
                "请先评估学生这次的回答是否真正答到这条追问的点上，再决定继续追问还是收束。"
            )
    else:
        lines.append("【上一轮追问与回答历史】（本题首轮，没有历史）")

    lines.append("")
    if purpose == "peer_assessment":
        lines.append(
            "【小组讨论 · 评估任务】你是围在旁边的**同班同学**，不是老师。"
            "只判断**本轮**你个人听懂没；`reason` 用口语（附和或求助），"
            "没听懂时只提 **1 个** 最卡的点。可以引用白板，但："
            "① 只有【学生口述】才能用「你说『…』」；"
            "② 步骤只能说「你写的」「白板上」；"
            "③ 【历史】里上一轮学生发言不要当成「本轮刚说的」；"
            "④ 白板仅有笔画时禁止猜内容；"
            "⑤ 禁止批作业腔、禁止导师式挑刺。"
        )
    elif purpose == "teacher":
        lines.append(
            "【提示任务】学生主动请求提示。可引用白板步骤或口述中的真实内容，"
            "但只有【学生口述】里的词句才能用「你说」；步骤用「你写的」描述。"
            "禁止编造学生没说过的话。"
        )
    elif speech or has_step_text:
        lines.append(
            "重要：学生已经给出口述或步骤说明，你必须**优先**围绕这些内容追问。"
            "若引用【学生口述】里的词句，用中文引号简短照搬；"
            "若引用步骤说明，用「你写的」而不是「你说」。"
        )
    else:
        lines.append(
            "学生没有提供口述或文字说明。请像**同学**一样邀请对方继续讲："
            "「你打算从哪一步开始？」「这一步你是怎么想的？」——"
            "不要念题面、不要用教师术语列清单。"
        )
    if purpose == "lecture":
        lines.append("请只输出一个 JSON 对象，符合上面的输出格式。")
    elif purpose == "peer_assessment":
        lines.append("请只输出评估 JSON（understood / reason / highlightStepIds）。")
    else:
        lines.append("请只输出提示 JSON（text / highlightStepIds）。")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# LLM 输出解析 & 校验
# ---------------------------------------------------------------------------


_FENCE_RE = re.compile(r"^\s*```(?:json)?\s*|\s*```\s*$", re.IGNORECASE)


def _strip_markdown_fence(raw: str) -> str:
    """去掉可能的 ```json ... ``` 包裹；保留内层 JSON。"""

    if not raw:
        return raw
    text = raw.strip()
    if text.startswith("```"):
        # 去掉首尾两个 fence
        text = _FENCE_RE.sub("", text)
    # 进一步取第一个 `{` 到最后一个 `}` 之间，避免模型前后写散文
    first = text.find("{")
    last = text.rfind("}")
    if first != -1 and last != -1 and last > first:
        text = text[first : last + 1]
    return text.strip()


def _looks_like_failure(raw: str) -> bool:
    """检测通用 chat 封装返回的友好失败字符串（API_KEY 缺失 / 异常）。"""

    if not raw:
        return True
    head = raw.lstrip()[:48]
    return head.startswith("⚠️") or head.startswith("调用失败")


def _coerce_int(value: Any, *, default: int) -> int:
    try:
        if isinstance(value, bool):
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse_and_validate(
    raw: str,
    *,
    allowed_step_ids: list[str],
) -> list[dict[str, Any]] | None:
    """把 LLM 字符串解析为已校验的 turns 列表。失败返回 None。"""

    if _looks_like_failure(raw):
        logger.warning("[lecture-agent] LLM 返回失败字符串：%s", raw[:80])
        return None

    cleaned = _strip_markdown_fence(raw)
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as e:
        logger.warning(
            "[lecture-agent] JSON 解析失败：%s | raw_head=%r", e, cleaned[:120]
        )
        return None

    if not isinstance(payload, dict):
        logger.warning("[lecture-agent] LLM 返回非对象顶层：%r", type(payload))
        return None

    raw_turns = payload.get("turns")
    if not isinstance(raw_turns, list) or not raw_turns:
        logger.warning("[lecture-agent] turns 字段缺失或为空")
        return None

    if len(raw_turns) > 1:
        logger.warning("[lecture-agent] turns 超过 1 条，只保留首条")
        raw_turns = raw_turns[:1]

    allowed_set = set(allowed_step_ids)
    fallback_step = allowed_step_ids[0] if allowed_step_ids else None

    validated: list[dict[str, Any]] = []
    for idx, item in enumerate(raw_turns, start=1):
        if not isinstance(item, dict):
            logger.warning("[lecture-agent] turn[%d] 不是对象，跳过", idx)
            continue

        role = str(item.get("role", "")).strip().lower()
        if role not in _ALLOWED_ROLES:
            logger.warning("[lecture-agent] turn[%d] 非法 role=%r，跳过", idx, role)
            continue

        text = str(item.get("text", "")).strip()
        if not text:
            logger.warning("[lecture-agent] turn[%d] text 为空，跳过", idx)
            continue
        if len(text) > _MAX_TEXT_LEN:
            text = text[:_MAX_TEXT_LEN].rstrip() + "…"

        display = str(item.get("displayName") or "").strip() or _DEFAULT_DISPLAY_NAME[role]

        highlight_raw = item.get("highlightStepIds") or []
        if not isinstance(highlight_raw, list):
            highlight_raw = []
        highlight: list[str] = []
        for sid in highlight_raw:
            sid_str = str(sid).strip()
            if sid_str and sid_str in allowed_set and sid_str not in highlight:
                highlight.append(sid_str)
        if not highlight:
            if fallback_step is None:
                logger.warning(
                    "[lecture-agent] turn[%d] highlightStepIds 全不命中且无可回退步骤，跳过",
                    idx,
                )
                continue
            highlight = [fallback_step]

        validated.append(
            {
                "turn_id": f"turn_{len(validated) + 1}",
                "role": role,
                "display_name": display,
                "text": text,
                "highlight_step_ids": highlight,
            }
        )

    if not validated:
        logger.warning("[lecture-agent] 校验后 turns 为空")
        return None

    return validated


def _coerce_status(raw_value: Any) -> str:
    value = str(raw_value or "").strip().lower()
    if value in _ALLOWED_STATUS:
        return value
    return "needs_explanation"


def _coerce_mastery_delta(raw_value: Any) -> int:
    delta = _coerce_int(raw_value, default=0)
    if delta not in _ALLOWED_DELTA:
        # 截断到 [-1, 1]
        if delta > 1:
            return 1
        if delta < -1:
            return -1
        return 0
    return delta


# ---------------------------------------------------------------------------
# 对外入口
# ---------------------------------------------------------------------------


def generate_lecture_turns(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """生成一轮多 Agent 追问。

    返回结构（与 `LectureSubmitResponse` 字段对齐，便于路由层直接构造模型）：
    ```python
    {
        "status": "needs_explanation" | "completed",
        "mastery_delta": -1 | 0 | 1,
        "turns": [
            {
                "turn_id": "turn_1",
                "role": "xiaoming",
                "display_name": "小明",
                "text": "……",
                "highlight_step_ids": ["step_1"],
            },
            ...
        ],
        "source": "llm",
    }
    ```

    `source` 仅用于日志/调试，路由层不要原样塞给前端。

    - `round_index`：本题是第几次提交，从 1 开始。
    - `history`：当前题目内的对话历史（只取最近若干条，service 内还会再清洗）。
    """

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]

    cleaned_history = _sanitize_history(history)
    has_history = bool(cleaned_history)
    # round_index 防御：< 1 视为 1，避免上游打错数字污染多轮判断。
    safe_round = max(1, int(round_index or 1))

    if not Config.DEEPSEEK_API_KEY or Config.DEEPSEEK_API_KEY == "your_deepseek_api_key_here":
        logger.error(
            "[lecture-agent] DEEPSEEK_API_KEY 未配置 section=%s round=%d",
            section_id,
            safe_round,
        )
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    user_prompt = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
        history=cleaned_history,
    )

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]

    # 直接走 `deepseek_client.chat.completions.create(...)`：
    #   - 用 DeepSeek-V4-Flash，靠 `extra_body.thinking.type=disabled` 关思考。
    #   - `response_format={"type":"json_object"}` 双保险地约束 LLM 输出 JSON。
    #   - `timeout` 走 OpenAI SDK 自带的 per-request 超时（秒），超时即抛
    #     `APITimeoutError`，被外层 `except Exception` 接住后显式返回错误。
    #   - `.with_options(max_retries=0)`：OpenAI Python SDK 默认遇 timeout /
    #     5xx 会自动 retry 2 次，会把一次 25s 超时翻成 50-75s 真实卡顿。
    #     显式关掉，让超时只发生一次。
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_LECTURE_MODEL,
            messages=messages,
            temperature=_LECTURE_TEMPERATURE,
            max_tokens=1200,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=_LECTURE_EXTRA_BODY,
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001 — OpenAI-compatible SDK 可能抛任意异常
        logger.exception("[lecture-agent] LLM 调用异常：%s", e)
        raise LectureAgentError(f"LLM request failed: {e}") from e

    turns = _parse_and_validate(raw or "", allowed_step_ids=allowed_step_ids)
    if not turns:
        logger.warning(
            "[lecture-agent] 解析/校验失败 section=%s raw_head=%r",
            section_id,
            (raw or "")[:120],
        )
        raise LectureAgentError("LLM response could not be parsed into valid turns")

    # 现在再次尝试读 status/masteryDelta；若失败则显式报错。
    payload_obj: dict[str, Any]
    try:
        payload_obj = json.loads(_strip_markdown_fence(raw))
        if not isinstance(payload_obj, dict):
            payload_obj = {}
    except json.JSONDecodeError as e:
        raise LectureAgentError("LLM response JSON was invalid") from e

    final_status = "needs_explanation"
    final_delta = 0

    logger.info(
        "[lecture-agent] 使用 LLM 真实剧本 section=%s round=%d history=%d "
        "status=%s turns=%d",
        section_id,
        safe_round,
        len(cleaned_history),
        final_status,
        len(turns),
    )

    return {
        "status": final_status,
        "mastery_delta": final_delta,
        "turns": turns,
        "source": "llm",
    }
