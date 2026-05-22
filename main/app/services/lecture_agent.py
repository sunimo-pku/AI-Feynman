"""讲题 / 多 Agent 追问的 LLM 剧本生成服务。

设计要点：

- **单大模型多角色剧本**：用同一次 LLM 调用让 DeepSeek 同时扮演小明 / 大雄 / 班长 /
  李老师中的 1-2 个角色，避免 N 次串行调用拉爆延迟。
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
  「在回答上一轮 AI 追问」还是「重新讲一遍」，并据此决定 `status` 是
  `needs_explanation` 还是 `completed`。
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any

from app.config import Config
from app.services.kimi import DEEPSEEK_THINKING_DISABLED, deepseek_client
from app.services import knowledge_index

logger = logging.getLogger(__name__)


class LectureAgentError(RuntimeError):
    """Raised when the LLM lecture agent cannot produce a valid turn."""


_LECTURE_MODEL = Config.DEEPSEEK_MODEL
_LECTURE_TEMPERATURE = 0.3
_LECTURE_EXTRA_BODY: dict[str, Any] = DEEPSEEK_THINKING_DISABLED

# 非实时 `/lecture/submit` 仍需要等待完整 JSON；实时讲题走
# `lecture_agent_stream.py`，首 token 超过 2 秒会直接报错。
_LLM_TIMEOUT_SECONDS = 6.0


# ---------------------------------------------------------------------------
# 常量 & 角色映射
# ---------------------------------------------------------------------------


_ALLOWED_ROLES: tuple[str, ...] = ("xiaoming", "daxiong", "monitor", "teacher")
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


_SYSTEM_PROMPT = """你是「初中数学费曼学习小组剧本导演」。
学生正在面向人教版初中数学任意章节题目做费曼讲题。
你必须扮演他们的同伴和老师，用追问帮学生发现自己的卡点。

【角色清单】每次只挑选 1-2 个最合适的角色发言：
- xiaoming（小明）：基础不牢，追问定义、条件、为什么这一步成立。
- daxiong（大雄）：粗心型同学，专门盯计算细节、化简错误、漏写条件。
- monitor（班长）：归纳总结型，要求把方法、步骤、易错点提炼成一句话规则。
- teacher（李老师）：温和的老师，做脚手架式引导和收束，不直接公布答案。

【任务规则】
1. 围绕本题与本节核心知识点，不要泛泛聊「加油」「你真棒」。
2. 不要一次性把答案告诉学生；老师只做引导和小结。
3. 不要嘲讽、阴阳怪气；语气友好、平视、尊重学生。
4. 如果学生写的步骤太少或语焉不详，优先追问「这一步为什么成立」。
5. 数学符号用 LaTeX：例如 `\\frac{a}{b}`、`x \\ge 0`、`\\angle A`、`y=kx+b`。
   推导时尽量带适用条件，比如定义域、正负号、等价变形条件、几何图形条件、统计口径。
6. 每条发言必须挂在 `highlightStepIds` 上，且只能引用「允许的 stepId 白名单」里的值。
7. 每条发言不超过 180 个中文字符。
8. 整体最多 2 条发言。
9. 根据【当前小节】和【题面】判断本题所属领域，再选择相应的追问角度。

【使用学生本人输入】
10. 如果用户提供了「学生口述」或某些 step 的「文字说明 / latex」，你必须**优先**围绕
   学生自己说出来的内容追问，而不是空对空念题面。例如：
   - 有理数题：学生说「负负得正」 → 追问符号法则和括号处理是否一致。
   - 方程题：学生把两边同除以某个式子 → 追问这个式子能不能为 0，是否丢根。
   - 函数题：学生说「斜率越大越陡」 → 追问 $k$ 的正负和图像经过象限。
   - 几何题：学生用全等/相似 → 追问对应边角是否对应，条件是否足够。
   - 统计题：学生比较平均数 → 追问样本量、极端值和方差是否也要看。
11. 不要把学生输入当作正确答案：它可能里面藏着前提条件缺失、化简规则用错、计算
    符号错误等，你要像同学/老师一样**逐条质疑**。常见追问角度：
    - 定义有没有说清？量、单位、符号、图形条件是否完整？
    - 这一步是不是等价变形？有没有除以 0、开平方正负、取交集/并集、约分条件？
    - 公式/定理适用条件是否满足？对应关系、定义域、样本口径是否一致？
    - 计算有没有漏负号、括号、单位、近似精度、分类讨论？
12. 引用学生原话时**用引号**简短照搬，让学生明确感到「AI 真的在听我讲」。
13. 如果「学生口述」和所有 step 文字都为空，也必须根据【题面】和【当前小节】
    选择本题所属领域的核心概念追问。

【反幻觉 · 硬约束】
H1. 你看到的「学生口述」(`student_speech_text`) 来自语音转写，可能很短甚至几个字。
    **绝对禁止**编造学生没说过的话作为他的口述、绝对禁止「学生说『XXX』」这种
    引号内容，除非引号里的词原样出现在 `student_speech_text` 里。
H2. 如果 `student_speech_text` 整段非空字符 < 5（例如学生只说了「嗯」「这个」
    「然后」），**第一条** Agent 发言**必须**是开放邀请语，例如「你能再讲一句
    自己的思路吗？」或「这一步你是怎么想的？」 —— **绝对不要**基于题面替学生
    推导一遍他还没讲的内容。
H3. 你只能基于 step 上**真实存在**的 `latex` / `plainText` 做追问；不要替学生
    脑补他还没写下来的下一步。如果 step 内容为空、口述也短，老老实实让学生
    继续讲。
H4. 题面里没有明文出现的数值、符号、公式，**绝对不要**写进追问里假装是学生
    给的条件。换句话说：宁可让 AI 显得"问得简单"，也不要让 AI 显得"懂的
    比学生多 + 编"。学生最讨厌"AI 在替我做题"。

【多轮追问规则】
14. 当上下文提供「上一轮历史」时，请先判断：学生这一轮的口述/步骤说明
    到底是「在回答上一轮 AI 追问」还是「在重新讲一遍 / 改了写法」。
15. 如果是在回答上一轮追问：
    a. **不要重复**上一轮已经问过的问题；要先用 1 句话评价学生答得到不到位
       （比如老师说「对，这次你补出了公式的适用条件」）。
    b. 若学生把规则、前提条件、计算依据都讲清楚了 —— 输出 `status: "completed"`、
       `masteryDelta: 1`，并且 `turns` 仅放 1 条「李老师」收束发言。
    c. 若学生只复述结论、没解释「为什么」—— 继续 `needs_explanation`，
       由 1 名 Agent 顺着学生这次说的话往**下一层**追问（不要回到上一轮原问题）。
16. 如果学生没回答上一轮追问、而是改写了步骤：可以由小明 / 大雄追问「为什么改」，
    然后再针对新写法继续追问。
17. 收束 `completed` 时务必让学生看出「这一题讲清楚了」：
    - role 必须是 `teacher`；
    - text 中要复述学生抓到的关键规则（例如定义、定理条件、等价变形依据或计算检查点）；
    - `highlightStepIds` 仍只能命中白名单。

【输出格式】
只输出**一个 JSON 对象**，不要 Markdown 代码块、不要解释、不要前后缀。
JSON 必须严格匹配：
{
  "status": "needs_explanation" | "completed",
  "masteryDelta": -1 | 0 | 1,
  "turns": [
    {
      "role": "xiaoming" | "daxiong" | "monitor" | "teacher",
      "displayName": "小明" | "大雄" | "班长" | "李老师",
      "text": "……（含 LaTeX，不超过 180 中文字符）",
      "highlightStepIds": ["step_x"]
    }
  ]
}
"""


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


def _last_ai_followup(history: list[dict[str, Any]]) -> dict[str, Any] | None:
    """从已清洗的 history 中找到「最近一条 AI 追问」（小明 / 大雄 / 班长 / 老师）。"""

    for item in reversed(history):
        if item["role"] in ("xiaoming", "daxiong", "monitor", "teacher"):
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
        lines.append(f'【学生口述（学生本人原话）】"{speech}"')
    else:
        lines.append("【学生口述】（学生没有补充口述文字）")
    lines.append("")
    lines.append("【学生手写步骤 + 学生本人写的步骤说明】按提交顺序，每行一条：")
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
                descr_bits.append(f'学生自述="{plain}"')
            if latex:
                descr_bits.append(f"学生写的 LaTeX=`{latex}`")
            if not plain and not latex:
                descr_bits.append("（学生未补充文字说明）")
            descr_bits.append(f"笔画数={strokes}")
            lines.append(f"- {sid}: " + "; ".join(descr_bits))

    lines.append("")
    lines.append(
        "【允许引用的 stepId 白名单】只能从下列 ID 中挑选，"
        "不允许编造任何不在该列表中的 stepId："
    )
    lines.append("- " + (", ".join(allowed_step_ids) if allowed_step_ids else "（空）"))

    lines.append("")
    last_followup = _last_ai_followup(history)
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
        if last_followup is not None:
            lines.append("")
            lines.append(
                f'重要：上一轮 AI（{last_followup["display_name"]}，role={last_followup["role"]}）'
                f'追问的是 "{last_followup["text"]}"。'
                "请先评估学生这次的回答是否真正答到这条追问的点上，再决定继续追问还是收束。"
            )
    else:
        lines.append("【上一轮追问与回答历史】（本题首轮，没有历史）")

    lines.append("")
    if speech or has_step_text:
        lines.append(
            "重要：学生已经给出口述或步骤说明，你必须**优先**抓住学生的原话来追问。"
            "至少有一条发言要明显引用学生"
            "说过的关键短语（用中文引号简短照搬），并质疑其中可能藏的前提条件 / "
            "化简规则 / 计算符号问题。"
        )
    else:
        lines.append(
            "学生没有提供口述或文字说明。请根据【当前小节】和【题面】判断本题所属领域，"
            "再追问该领域最关键的定义、"
            "公式适用条件、等价变形依据、图形关系、函数关系或统计口径。"
        )
    lines.append("请只输出一个 JSON 对象，符合上面的输出格式。")

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

    if len(raw_turns) > 2:
        raw_turns = raw_turns[:2]

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

    final_status = _coerce_status(payload_obj.get("status"))
    final_delta = _coerce_mastery_delta(payload_obj.get("masteryDelta"))

    # 防御一种常见 LLM 走样：第一轮就直接 `completed`。学生连题面都没解释完，
    # 不应该被「这一题讲清楚了」收束 —— 强制改回 `needs_explanation`。
    # 多轮场景下 LLM 自己判定 completed 是合理的，我们不动。
    if safe_round <= 1 and final_status == "completed":
        logger.warning(
            "[lecture-agent] 第一轮 LLM 直接给出 completed，强制改为 needs_explanation"
        )
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
