"""独立教师 Agent：仅在学生主动请求「提示」时发言。

与同伴追问 Agent（`lecture_agent`）分离 API 与 System Prompt，避免角色混用。
"""

from __future__ import annotations

import json
import logging
from typing import Any

from app.config import Config
from app.services.kimi import DEEPSEEK_THINKING_DISABLED, deepseek_client
from app.services.lecture_agent import (
    LectureAgentError,
    _build_user_prompt,
    _sanitize_history,
    _strip_markdown_fence,
)
from app.services.question_bank import resolve_standard_answer

logger = logging.getLogger(__name__)

_TEACHER_MODEL = Config.DEEPSEEK_MODEL
_TEACHER_TEMPERATURE = 0.3
_TEACHER_EXTRA_BODY: dict[str, Any] = DEEPSEEK_THINKING_DISABLED
_LLM_TIMEOUT_SECONDS = 6.0
_MAX_TEXT_LEN = 220
_MAX_SUMMARY_TEXT_LEN = 140
_MAX_METHOD_SUMMARY_LEN = 180

_TEACHER_SYSTEM_PROMPT = """你是初中数学讲题课的李老师。
**只有当学生主动点击「需要提示」时**，你才发言；平时不参与同伴追问。

【你的任务】
1. 温和脚手架式引导，帮学生自己发现下一步该想什么；
2. **绝不**直接公布完整答案，也不替学生做完推导；
3. 可以指出「该检查哪个概念 / 条件 / 定义域」，最多给半句方向性暗示；
4. 优先引用学生已写步骤或口述中的**真实**内容（禁止编造）；
5. 语气友好、尊重；数学符号用 LaTeX；
6. 发言不超过 180 个中文字符；
7. `highlightStepIds` 只能引用白名单里的 stepId。

【反幻觉】
- 禁止编造学生没说过的话；
- 不要替学生脑补还没写下来的步骤；
- 题面里没出现的数值 / 公式，不要假装是学生给的。

只输出**一个 JSON 对象**，不要 Markdown 代码块：
{
  "text": "……（含 LaTeX，不超过 180 中文字符）",
  "highlightStepIds": ["step_x"]
}
"""


def generate_teacher_hint(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """生成一条李老师提示 turn。"""

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]

    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))

    if not Config.DEEPSEEK_API_KEY or Config.DEEPSEEK_API_KEY == "your_deepseek_api_key_here":
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    context_prompt = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
        history=cleaned_history,
        purpose="teacher",
    )
    user_prompt = (
        "【学生请求】学生刚刚主动点击了「需要提示」。请给出一条脚手架式提示，"
        "不要直接给答案。\n\n"
        f"{context_prompt}\n\n"
        "请只输出一个 JSON 对象，符合上面的输出格式。"
    )

    messages = [
        {"role": "system", "content": _TEACHER_SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ]

    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_TEACHER_MODEL,
            messages=messages,
            temperature=_TEACHER_TEMPERATURE,
            max_tokens=600,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=_TEACHER_EXTRA_BODY,
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[teacher-agent] LLM 调用异常：%s", e)
        raise LectureAgentError(f"Teacher hint LLM request failed: {e}") from e

    try:
        payload = json.loads(_strip_markdown_fence(raw or ""))
        if not isinstance(payload, dict):
            raise ValueError("top-level not object")
    except (json.JSONDecodeError, ValueError) as e:
        raise LectureAgentError("Teacher hint response could not be parsed") from e

    text = str(payload.get("text") or "").strip()
    if not text:
        raise LectureAgentError("Teacher hint text is empty")
    if len(text) > _MAX_TEXT_LEN:
        text = text[:_MAX_TEXT_LEN].rstrip() + "…"

    allowed_set = set(allowed_step_ids)
    fallback_step = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback_step:
        highlight = [fallback_step]

    logger.info(
        "[teacher-agent] hint ok section=%s round=%d history=%d",
        section_id,
        safe_round,
        len(cleaned_history),
    )

    return {
        "turn_id": "hint_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": text,
        "highlight_step_ids": highlight,
        "source": "llm",
    }


_TEACHER_SUMMARY_PROMPT = """你是初中数学讲题课的李老师。
同伴评估显示三名同学都听懂了，但**你必须独立核对**学生讲解数学是否正确。

【首要任务 · 核对】
对照【标准解答要点】（若有）或题面自行推理：
- 若学生**明显讲错**（法则用错、漏条件、结果错、与标准要点矛盾）：
  `"approved": false`，`text` 温和指出**哪一类**问题（不要直接给完整正确答案），
  `methodSummary` 留空 `""`。
- 若数学上**站得住**：
  `"approved": true`，`text` 肯定学生本轮讲清楚的关键点；
  `methodSummary` 用 2～3 句话归纳此类题通用方法。

【表达】
- 语气温和；数学用 LaTeX；`text` ≤120 字，`methodSummary` ≤160 字；
- `highlightStepIds` 只能引用白名单 stepId。
- 禁止写「大雄验证了…」等仿佛同伴刚才发言；最多一句「同伴们都听懂了」。

只输出一个 JSON 对象：
{
  "approved": true | false,
  "text": "……",
  "methodSummary": "……",
  "highlightStepIds": ["step_x"]
}
"""


def _peer_understood_ack(peer_assessments: list[dict[str, Any]] | None) -> str:
    """收束小结用：只传「谁听懂了」，不传 assessment reason（避免李老师转述未开口的同伴）。"""
    order = ("小明", "大雄", "班长")
    name_by_role = {
        "xiaoming": "小明",
        "daxiong": "大雄",
        "monitor": "班长",
        "classleader": "班长",
    }
    understood: set[str] = set()
    for item in peer_assessments or []:
        if not isinstance(item, dict) or not bool(item.get("understood")):
            continue
        display = str(item.get("display_name") or item.get("displayName") or "").strip()
        role = str(item.get("role") or "").strip().lower()
        if display:
            understood.add(display)
        elif role in name_by_role:
            understood.add(name_by_role[role])
    if not understood:
        return "三名同伴均表示听懂（本轮未当众发言）。"
    ordered = [n for n in order if n in understood]
    for n in sorted(understood):
        if n not in ordered:
            ordered.append(n)
    return "、".join(ordered) + "均表示听懂（本轮未当众发言）。"


def apply_teacher_completion_gate(
    result: dict[str, Any],
    teacher_summary: dict[str, Any] | None,
) -> dict[str, Any]:
    """李老师核对不通过时，禁止 completed。"""
    if teacher_summary is None or bool(teacher_summary.get("approved", True)):
        return result
    patched = dict(result)
    patched["status"] = "needs_explanation"
    patched["all_understood"] = False
    patched["mastery_delta"] = 0
    return patched


def generate_teacher_summary(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
    peer_assessments: list[dict[str, Any]] | None = None,
    standard_answer: str = "",
) -> dict[str, Any]:
    """三名同伴都听懂时，李老师收束小结。"""

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]
    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))

    if not Config.DEEPSEEK_API_KEY or Config.DEEPSEEK_API_KEY == "your_deepseek_api_key_here":
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    std = resolve_standard_answer(
        question_id=question_id,
        client_answer=standard_answer,
    )
    context_prompt = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
        history=cleaned_history,
        purpose="teacher_summary",
        standard_answer=std,
    )
    peer_ack = _peer_understood_ack(peer_assessments)

    user_prompt = (
        "【收束场景】同伴评估为全员听懂，但**你必须独立核对数学是否正确**。"
        "下列听懂确认不是同伴当众说过的话。\n"
        f"【同伴听懂确认】{peer_ack}\n\n"
        f"{context_prompt}\n\n"
        "请只输出一个 JSON 对象（含 approved 字段）。"
    )
    messages = [
        {"role": "system", "content": _TEACHER_SUMMARY_PROMPT},
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_TEACHER_MODEL,
            messages=messages,
            temperature=_TEACHER_TEMPERATURE,
            max_tokens=700,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=_TEACHER_EXTRA_BODY,
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[teacher-agent] summary LLM failed: %s", e)
        raise LectureAgentError(f"Teacher summary LLM failed: {e}") from e

    try:
        payload = json.loads(_strip_markdown_fence(raw or ""))
        if not isinstance(payload, dict):
            raise ValueError("top-level not object")
    except (json.JSONDecodeError, ValueError) as e:
        raise LectureAgentError("Teacher summary response could not be parsed") from e

    text = str(payload.get("text") or "").strip()
    if not text:
        raise LectureAgentError("Teacher summary text is empty")
    if len(text) > _MAX_SUMMARY_TEXT_LEN:
        text = text[:_MAX_SUMMARY_TEXT_LEN].rstrip() + "…"

    method_summary = str(
        payload.get("methodSummary") or payload.get("method_summary") or ""
    ).strip()
    if len(method_summary) > _MAX_METHOD_SUMMARY_LEN:
        method_summary = method_summary[:_MAX_METHOD_SUMMARY_LEN].rstrip() + "…"

    approved = bool(payload.get("approved", True))
    if not approved:
        method_summary = ""

    allowed_set = set(allowed_step_ids)
    fallback_step = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback_step:
        highlight = [fallback_step]

    logger.info(
        "[teacher-agent] summary ok section=%s round=%d approved=%s",
        section_id,
        safe_round,
        approved,
    )

    return {
        "turn_id": "summary_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": text,
        "method_summary": method_summary,
        "highlight_step_ids": highlight,
        "approved": approved,
        "source": "llm",
    }
