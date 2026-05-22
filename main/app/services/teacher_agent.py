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

logger = logging.getLogger(__name__)

_TEACHER_MODEL = Config.DEEPSEEK_MODEL
_TEACHER_TEMPERATURE = 0.3
_TEACHER_EXTRA_BODY: dict[str, Any] = DEEPSEEK_THINKING_DISABLED
_LLM_TIMEOUT_SECONDS = 6.0
_MAX_TEXT_LEN = 220

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
小明、大雄、班长**都已听懂**学生的讲解。请给出收束小结：

1. 复述学生自己讲清楚的关键规则 / 依据 / 检查点（不要直接报完整答案）；
2. 语气温和、肯定学生的费曼讲解；
3. 数学用 LaTeX；不超过 180 字；
4. `highlightStepIds` 只能引用白名单 stepId。

只输出一个 JSON 对象：
{
  "text": "……",
  "highlightStepIds": ["step_x"]
}
"""


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
    peer_lines = []
    for item in peer_assessments or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("display_name") or item.get("displayName") or "")
        reason = str(item.get("reason") or "").strip()
        if reason:
            peer_lines.append(f"- {name}：{reason}")
    peer_block = "\n".join(peer_lines) if peer_lines else "（同伴均表示听懂）"

    user_prompt = (
        "【收束场景】三名同伴本轮都已听懂。\n"
        f"【同伴听懂反馈】\n{peer_block}\n\n"
        f"{context_prompt}\n\n"
        "请只输出一个 JSON 对象。"
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

    logger.info("[teacher-agent] summary ok section=%s round=%d", section_id, safe_round)

    return {
        "turn_id": "summary_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": text,
        "highlight_step_ids": highlight,
        "source": "llm",
    }
