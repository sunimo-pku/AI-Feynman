"""讲题 / 多 Agent 追问的 LLM 剧本生成服务。

设计要点（覆盖第三 ~ 第五轮的 brief）：

- **单大模型多角色剧本**：用同一次 LLM 调用让 Kimi 同时扮演小明 / 大雄 / 班长 /
  李老师中的 1-2 个角色，避免 N 次串行调用拉爆延迟。
- **强 Schema 防御**：System Prompt 限定「只输出 JSON」、`response_format=json_object`
  双保险；解析时还要再做 markdown 去壳 + 字段白名单校验。
- **highlightStepIds 必须命中真实 stepId**：模型最爱编造 `step_99`，路由层会把
  真实白名单注入 Prompt，service 还会再过滤一次，命中不到的直接落回画板首步。
- **Fallback 优先于报错**：Demo 链路不能因为 Kimi 抽风、JSON 抽风、网络抽风而中断；
  解析失败一律回落到第二/五轮的固定 Mock 剧本，保留 `source=fallback` 日志便于排查。
- **不持有路由层依赖**：本模块只产出 `dict`（与 Pydantic schema 对齐的字段），
  由 `routers/lecture.py` 负责套上 `LectureSubmitResponse`。这样 service 既可
  被路由调用，也方便后续单测。
- **第五轮新增「多轮上下文」**：`generate_lecture_turns(...)` 多收两个参数
  `round_index` 与 `history`。Prompt 用最近 6 条历史让 LLM 评估学生本轮是
  「在回答上一轮 AI 追问」还是「重新讲一遍」，并据此决定 `status` 是
  `needs_explanation` 还是 `completed`。Fallback 也按 `round_index` 切换文案，
  避免学生连点两次都看到一模一样的兜底追问。
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from app.config import Config
# 复用 kimi.py 里已经实例化好的 OpenAI client（指向 Moonshot），
# 而不是新建一套。`kimi.chat(...)` 内部强制把 model 锁回 `Config.KIMI_MODEL`
# 且把 `extra_body` 这种 OpenAI SDK 扩展参数全吞掉，没法关 K2.6 的思考开关，
# 所以这里绕过 `chat()` 封装直连 `kimi_client`，让我们能显式选择模型 +
# 透传 `thinking={"type":"disabled"}` 把 K2.6 切到非思考模式。
from app.services.kimi import kimi_client
from app.services import knowledge_index

logger = logging.getLogger(__name__)


# Kimi 旗舰模型 K2.6 + **关闭思考模式**：
#   - 默认开"思考"时，K2.6 会先把推理塞 `reasoning_content` 再写 `content`，
#     单次 30-90s，且 `max_tokens=1200` 经常 `finish_reason=length`+空 `content`，
#     对"学生提交后等 AI 同伴追问"的体感完全不可接受。
#   - 通过 `extra_body={"thinking":{"type":"disabled"}}` 关掉思考后，
#     K2.6 在我们的 Prompt 上实测 3-6s 即可返回合规 JSON，
#     既保住了旗舰模型对中文数学语境 + LaTeX 输出的理解力，
#     又把延迟压到 Demo 可接受范围。
_LECTURE_MODEL = "kimi-k2.6"

# K2.6 关思考模式后 Moonshot 仍硬约束 `temperature=0.6`，传其他值会 400
# `invalid temperature: only 0.6 is allowed for this model`。
# 思考模式下要求 1.0、关思考后要求 0.6，是两套独立约束，切模型时都要重测。
_LECTURE_TEMPERATURE = 0.6

# 透传给 Moonshot 的扩展参数。OpenAI Python SDK 用 `extra_body` 透传
# 非 OpenAI 标准字段；Moonshot 这边是 `thinking: {type: enabled|disabled}`。
_LECTURE_EXTRA_BODY: dict[str, Any] = {"thinking": {"type": "disabled"}}

# 后端层 LLM 调用超时（秒）。K2.6 关思考实测中位数 5-15s，偶发
# 20-25s 拖尾（Moonshot 侧排队 + 长 Prompt 生成）。给 28s 既能盖住
# 大部分拖尾，又比 Flutter 客户端 30s timeout 短 2s —— 让前端先于
# 后端断开的概率最低，避免「前端报错 / 后端却拿到结果」的不一致。
_LLM_TIMEOUT_SECONDS = 28.0


# ---------------------------------------------------------------------------
# 常量 & 角色映射
# ---------------------------------------------------------------------------


_ALLOWED_ROLES: tuple[str, ...] = ("xiaoming", "daxiong", "monitor", "teacher")
_ALLOWED_STATUS: tuple[str, ...] = ("needs_explanation", "completed")
_ALLOWED_DELTA: tuple[int, ...] = (-1, 0, 1)

# 第五轮：history 项里允许的 role。`student` / `system` 不在 LLM 输出
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

_SECTION_TITLE: dict[str, str] = {
    "pep-g8-down-s16-1": "16.1 二次根式的概念与取值范围",
    "pep-g8-down-s16-2": "16.2 二次根式的乘除",
    "pep-g8-down-s16-3": "16.3 二次根式的加减",
}


_SYSTEM_PROMPT = """你是「初中数学费曼学习小组剧本导演」。
学生正在面向「人教版八年级下册 · 第十六章 二次根式」做费曼讲题。
你必须扮演他们的同伴和老师，用追问帮学生发现自己的卡点。

【角色清单】每次只挑选 1-2 个最合适的角色发言：
- xiaoming（小明）：基础不牢，追问定义、条件、为什么这一步成立。
- daxiong（大雄）：粗心型同学，专门盯计算细节、化简错误、漏写条件。
- monitor（班长）：归纳总结型，要求把方法、步骤、易错点提炼成一句话规则。
- teacher（李老师）：温和的老师，做脚手架式引导和收束，不直接公布答案。

【硬性规则】
1. 围绕本题与本节核心知识点，不要泛泛聊「加油」「你真棒」。
2. 不要一次性把答案告诉学生；老师只做引导和小结。
3. 不要嘲讽、阴阳怪气；语气友好、平视、尊重学生。
4. 如果学生写的步骤太少或语焉不详，优先追问「这一步为什么成立」。
5. 数学符号用 LaTeX：`\\sqrt{12}`、`\\frac{a}{b}`、`a \\cdot b`、`x \\ge 0`，
   推导时尽量带条件，比如「需要 a \\ge 0, b \\ge 0」。
6. 每条发言必须挂在 `highlightStepIds` 上，且只能引用「允许的 stepId 白名单」里的值。
7. 每条发言不超过 180 个中文字符。
8. 整体最多 2 条发言。

【优先使用学生本人输入】（这一节最重要）
9. 如果用户提供了「学生口述」或某些 step 的「文字说明 / latex」，你必须**优先**围绕
   学生自己说出来的内容追问，而不是空对空念题面。例如：
   - 学生口述「我把 12 拆成 4×3」 → 追问「为什么 4 可以从根号里出来？这条规则的前提是什么？」
   - 学生 step_2 写「根号 27 化成 3 根号 3」 → 追问「27 你是怎么拆的？拆成 9×3 还是 3×9，对最终结果有什么区别？」
   - 学生口述「最后得到负一根号三」 → 追问「同类二次根式相减时，系数 2 减 3 是怎么得到 -1 的？这里要不要写括号？」
10. 不要把学生输入当作正确答案：它可能里面藏着前提条件缺失、化简规则用错、计算
    符号错误等，你要像同学/老师一样**逐条质疑**。常见追问角度：
    - 被开方数有没有非负条件？$\\ge 0$ 还是 $> 0$？
    - $\\sqrt{a}\\cdot\\sqrt{b}=\\sqrt{ab}$、$\\sqrt{a/b}=\\sqrt{a}/\\sqrt{b}$ 是否要求 $a,b\\ge 0$（除法时 $b>0$）？
    - 同类二次根式合并时，系数是否对齐、有没有漏负号？
    - 把 $\\sqrt{n}$ 化成 $k\\sqrt{m}$ 时，是否把完全平方数全部提出来了？
11. 引用学生原话时**用引号**简短照搬，让学生明确感到「AI 真的在听我讲」；
    比如：「你刚才说 “把 12 拆成 4×3”，那为什么不拆成 2×6 呢？」
12. 如果「学生口述」和所有 step 文字都为空，再回到泛泛追问本节核心知识点的兜底逻辑。

【多轮追问规则（第五轮新增）】
13. 当 user prompt 提供「上一轮历史」时，请先判断：学生这一轮的口述/步骤说明
    到底是「在回答上一轮 AI 追问」还是「在重新讲一遍 / 改了写法」。
14. 如果是在回答上一轮追问：
    a. **不要重复**上一轮已经问过的问题；要先用 1 句话评价学生答得到不到位
       （比如老师说「对，这次你说出 4 是完全平方数，所以 √4·3=2√3」）。
    b. 若学生把规则、前提条件、计算依据都讲清楚了 —— 输出 `status: "completed"`、
       `masteryDelta: 1`，并且 `turns` 仅放 1 条「李老师」收束发言。
    c. 若学生只复述结论、没解释「为什么」—— 继续 `needs_explanation`，
       由 1 名 Agent 顺着学生这次说的话往**下一层**追问（不要回到上一轮原问题）。
15. 如果学生没回答上一轮追问、而是改写了步骤：可以由小明 / 大雄追问「为什么改」，
    然后再针对新写法继续追问。
16. 收束 `completed` 时务必让学生看出「这一题讲清楚了」：
    - role 必须是 `teacher`；
    - text 中要复述学生抓到的关键规则（比如「你说出了 a≥0 的前提」）；
    - `highlightStepIds` 仍只能命中白名单。

【输出协议】
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

    任何异常都按「忽略本条」处理，绝不抛出 —— 这是按 ROUND5 brief 第 7.3 节
    要求：「不要因为 history 缺失或格式异常直接 500」。
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

    第四轮起 `studentSpeechText` 与 `steps[*].plainText / latex` 都来自学生
    自己在客户端输入区里手敲的内容（在 ASR/OCR 接入之前）。所以这里要把
    它们清楚地标成「学生自己说的话 / 学生自己写的步骤说明」，让 LLM 拿来
    当一手语义证据，而不是当成 OCR 二手识别结果。

    第五轮起新增「上一轮历史」段：让 LLM 明确知道「学生这次到底是在回答
    上一轮的哪一个 AI 追问」，从而避免每轮都问同样的问题、能在合适时机
    切到 `status: completed`。
    """

    section_title = _SECTION_TITLE.get(section_id, section_id)

    lines: list[str] = []
    lines.append(f"【当前小节】{section_title}（sectionId={section_id}）")
    lines.append(f"【本题第几轮提交】{round_index}")
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
        lines.append("【学生口述】（本轮学生没有补充口述文字）")
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
    # 第五轮：插入历史段。即便 history 为空也写一句标识，让 LLM 明确知道
    # 「这是第一轮 / 这是延续追问」，避免它自己脑补轮次状态。
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
                "请先评估学生本轮的回答是否真正答到这条追问的点上，按系统规则第 13-16 条决定 status。"
            )
    else:
        lines.append("【上一轮追问与回答历史】（本题首轮，没有历史）")

    lines.append("")
    if speech or has_step_text:
        lines.append(
            "重要：本轮学生已经给出口述或步骤说明，按系统规则第 9-11 条，"
            "你必须**优先**抓住学生的原话来追问。至少有一条发言要明显引用学生"
            "说过的关键短语（用中文引号简短照搬），并质疑其中可能藏的前提条件 / "
            "化简规则 / 计算符号问题。"
        )
    else:
        lines.append(
            "本轮学生没有提供口述或文字说明，按系统规则第 12 条回到泛泛追问，"
            "聚焦本节核心：二次根式的有意义条件 / 乘除合并条件 / 同类二次根式加减。"
        )
    lines.append("请只输出一个 JSON 对象，符合系统输出协议。")

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
    """检测 `kimi.chat(...)` 返回的"友好失败"字符串（API_KEY 缺失 / 异常）。"""

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
# 第二轮兜底剧本（与 routers/lecture.py 第二轮逻辑保持一致）
# ---------------------------------------------------------------------------


def _fallback_turns(
    section_id: str,
    step_ids: list[str],
    *,
    round_index: int = 1,
    has_history: bool = False,
) -> list[dict[str, Any]]:
    """LLM 失败时的兜底剧本。

    第二轮起作为「演示链路永不中断」的安全网，第五轮起会按 `round_index`
    输出不同文案：
      * `round_index <= 1` 或没有历史：保持原第一轮固定追问。
      * `round_index >= 2`：切到「老师顺势收束 + 让学生确认」的兜底文案，
        避免学生连点两次都被 Mock 同样的话追问。

    Fallback 的 status 仍由调用方（`generate_lecture_turns`）决定 ——
    第二轮以后的 fallback 默认改为 `completed`，让重复点击的体感更平滑。
    """

    first_step = step_ids[0] if step_ids else "step_1"
    mid_step = step_ids[len(step_ids) // 2] if step_ids else first_step
    last_step = step_ids[-1] if step_ids else first_step

    multi_round = round_index >= 2 or has_history
    if multi_round:
        # 多轮兜底：老师做温和收束，避免重复第一轮原问题。
        return [
            {
                "turn_id": "turn_1",
                "role": "teacher",
                "display_name": "李老师",
                "text": (
                    "嗯，从你刚才补的解释看，思路已经顺多了。我们这一题先到这里，"
                    "下次遇到类似的题，记得把「为什么这一步可以这么做」也念出来。"
                ),
                "highlight_step_ids": [mid_step],
            }
        ]

    if section_id == "pep-g8-down-s16-1":
        return [
            {
                "turn_id": "turn_1",
                "role": "xiaoming",
                "display_name": "小明",
                "text": (
                    "等等，被开方数是 $2x-6$，你怎么知道一定要让它 $\\ge 0$ 呀？"
                    "是不是因为负数开根号在实数范围里没意义？"
                ),
                "highlight_step_ids": [first_step],
            },
            {
                "turn_id": "turn_2",
                "role": "teacher",
                "display_name": "李老师",
                "text": (
                    "问得不错。你能不能再补一句：写完不等式 $2x-6 \\ge 0$ 之后，"
                    "怎么推出 $x \\ge 3$？"
                ),
                "highlight_step_ids": [last_step],
            },
        ]
    if section_id == "pep-g8-down-s16-2":
        return [
            {
                "turn_id": "turn_1",
                "role": "xiaoming",
                "display_name": "小明",
                "text": (
                    "你直接把 $\\sqrt{12} \\cdot \\sqrt{3}$ 写成 $\\sqrt{36}$，"
                    "这里用了一条法则吧？前提是什么呀？"
                ),
                "highlight_step_ids": [first_step],
            },
            {
                "turn_id": "turn_2",
                "role": "teacher",
                "display_name": "李老师",
                "text": (
                    "对的，要强调 $a \\ge 0$、$b \\ge 0$ 才能这样合并。"
                    "你能把这句条件补到你刚才那一步旁边吗？"
                ),
                "highlight_step_ids": [mid_step],
            },
        ]
    if section_id == "pep-g8-down-s16-3":
        return [
            {
                "turn_id": "turn_1",
                "role": "xiaoming",
                "display_name": "小明",
                "text": (
                    "我有点疑惑，$\\sqrt{12}$ 为什么可以变成 $2\\sqrt{3}$？"
                    "这里用了什么规律？"
                ),
                "highlight_step_ids": [first_step],
            },
            {
                "turn_id": "turn_2",
                "role": "teacher",
                "display_name": "李老师",
                "text": (
                    "这个问题问得很好。你可以试着把 12 拆成 $4 \\times 3$，"
                    "再说明为什么 4 能从根号里出来。同样地，$\\sqrt{27}$ 也试一下。"
                ),
                "highlight_step_ids": [mid_step],
            },
        ]
    # 章节白名单已在路由层挡住，这里再兜一次。
    return []


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
        "source": "llm" | "fallback",
    }
    ```

    `source` 仅用于日志/调试，路由层不要原样塞给前端。

    第五轮起新增两个可选参数：

    - `round_index`：本题是第几次提交，从 1 开始。
    - `history`：当前题目内的对话历史（只取最近若干条，service 内还会再清洗）。
    """

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]

    cleaned_history = _sanitize_history(history)
    has_history = bool(cleaned_history)
    # round_index 防御：< 1 视为 1，避免上游打错数字让 fallback 文案错乱。
    safe_round = max(1, int(round_index or 1))

    def _fallback_payload() -> dict[str, Any]:
        # 多轮 fallback：第 2+ 轮默认收束，避免重复第一轮 Mock。
        is_multi = safe_round >= 2 or has_history
        return {
            "status": "completed" if is_multi else "needs_explanation",
            "mastery_delta": 1 if is_multi else 0,
            "turns": _fallback_turns(
                section_id,
                allowed_step_ids,
                round_index=safe_round,
                has_history=has_history,
            ),
            "source": "fallback",
        }

    # KIMI_API_KEY 缺失时直接走 fallback，省一次失败请求。
    if not Config.KIMI_API_KEY or Config.KIMI_API_KEY == "your_kimi_api_key_here":
        logger.info(
            "[lecture-agent] KIMI_API_KEY 未配置，使用 fallback section=%s round=%d",
            section_id,
            safe_round,
        )
        return _fallback_payload()

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

    # 直接走 `kimi_client.chat.completions.create(...)`：
    #   - 用 `kimi-k2.6` 旗舰模型，靠 `extra_body.thinking.type=disabled` 关思考。
    #   - `response_format={"type":"json_object"}` 双保险地约束 LLM 输出 JSON。
    #   - `timeout` 走 OpenAI SDK 自带的 per-request 超时（秒），超时即抛
    #     `APITimeoutError`，被外层 `except Exception` 接住后回落 fallback。
    #   - `.with_options(max_retries=0)`：OpenAI Python SDK 默认遇 timeout /
    #     5xx 会自动 retry 2 次，对我们的"超时即回退"语义是反作用力 ——
    #     一次 25s 超时会被 SDK 翻成 50-75s 真实卡顿，前端早就报错了。
    #     显式关掉，让超时只发生一次。
    try:
        resp = kimi_client.with_options(max_retries=0).chat.completions.create(
            model=_LECTURE_MODEL,
            messages=messages,
            temperature=_LECTURE_TEMPERATURE,
            max_tokens=1200,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=_LECTURE_EXTRA_BODY,
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001 — Moonshot SDK 可能抛任意异常
        logger.exception("[lecture-agent] LLM 调用异常：%s", e)
        return _fallback_payload()

    turns = _parse_and_validate(raw or "", allowed_step_ids=allowed_step_ids)
    if not turns:
        logger.warning(
            "[lecture-agent] 解析/校验失败，使用 fallback section=%s raw_head=%r",
            section_id,
            (raw or "")[:120],
        )
        return _fallback_payload()

    # 现在再次尝试读 status/masteryDelta；解析失败时已经在上面 fallback 了，
    # 所以这里 raw 一定是合法 JSON 字符串。
    payload_obj: dict[str, Any]
    try:
        payload_obj = json.loads(_strip_markdown_fence(raw))
        if not isinstance(payload_obj, dict):
            payload_obj = {}
    except json.JSONDecodeError:
        payload_obj = {}

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
