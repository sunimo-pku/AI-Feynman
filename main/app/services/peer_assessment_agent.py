"""同伴听课评估：小明 / 大雄 / 班长各 1 次独立 LLM 调用。

P1：学生每提交一轮讲解，三人并行评估「听懂 / 没听懂」及理由。
全员听懂时由 `teacher_agent.generate_teacher_summary` 收束（在路由层触发）。
"""

from __future__ import annotations

import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from app.config import Config
from app.services.kimi import DEEPSEEK_THINKING_DISABLED, deepseek_client
from app.services.lecture_agent import (
    LectureAgentError,
    _DEFAULT_DISPLAY_NAME,
    _PEER_ROLES,
    _build_user_prompt,
    _sanitize_history,
    _strip_markdown_fence,
)
from app.services.peer_personas import (
    default_assessment_reason,
    build_peer_assessment_system_prompt,
    PEER_ASSESSMENT_USER_SUFFIX,
)

logger = logging.getLogger(__name__)

_ASSESSMENT_MODEL = Config.DEEPSEEK_MODEL
_ASSESSMENT_TEMPERATURE = 0.45
_ASSESSMENT_EXTRA_BODY: dict[str, Any] = DEEPSEEK_THINKING_DISABLED
_LLM_TIMEOUT_SECONDS = 6.0
_MAX_REASON_LEN = 220

# 「你说『…』」类表述：引号内必须出现在本轮 student_speech_text 里。
_SPEECH_QUOTE_RE = re.compile(
    r"(?:你说|你刚才说|你刚刚说)[「『\"']([^」』\"']{2,})[」』\"']"
)


def _system_prompt_for_role(role: str) -> str:
    return build_peer_assessment_system_prompt(role)


def _step_evidence_corpus(steps: list[dict[str, Any]]) -> str:
    bits: list[str] = []
    for s in steps:
        plain = str(s.get("plainText") or s.get("plain_text") or "").strip()
        latex = str(s.get("latex") or "").strip()
        if plain:
            bits.append(plain)
        if latex:
            bits.append(latex)
    return " ".join(bits)


def _sanitize_reason_quotes(
    reason: str,
    *,
    student_speech_text: str,
    steps: list[dict[str, Any]],
) -> str:
    """把误标成「你说」但不在口述里的引用，改成「你写的」或去掉。"""
    speech = (student_speech_text or "").strip()
    step_corpus = _step_evidence_corpus(steps)
    out = reason
    for match in list(_SPEECH_QUOTE_RE.finditer(reason)):
        quoted = match.group(1).strip()
        if not quoted:
            continue
        if quoted in speech:
            continue
        replacement = (
            f"你写的「{quoted}」"
            if quoted in step_corpus
            else "这里"
        )
        out = out.replace(match.group(0), replacement, 1)
    return out


def _parse_assessment(
    raw: str,
    *,
    role: str,
    allowed_step_ids: list[str],
    student_speech_text: str,
    steps: list[dict[str, Any]],
) -> dict[str, Any]:
    cleaned = _strip_markdown_fence(raw or "")
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise LectureAgentError(f"{role} assessment JSON invalid: {e}") from e
    if not isinstance(payload, dict):
        raise LectureAgentError(f"{role} assessment top-level not object")

    understood = bool(payload.get("understood"))
    reason = str(payload.get("reason") or "").strip()
    if not reason:
        reason = default_assessment_reason(role=role, understood=understood)
    reason = _sanitize_reason_quotes(
        reason,
        student_speech_text=student_speech_text,
        steps=steps,
    )
    if len(reason) > _MAX_REASON_LEN:
        reason = reason[:_MAX_REASON_LEN].rstrip() + "…"

    allowed_set = set(allowed_step_ids)
    fallback = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback:
        highlight = [fallback]

    return {
        "role": role,
        "display_name": _DEFAULT_DISPLAY_NAME[role],
        "understood": understood,
        "reason": reason,
        "highlight_step_ids": highlight,
    }


def _assess_one_peer(
    *,
    role: str,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
    history: list[dict[str, Any]],
) -> dict[str, Any]:
    context = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=history,
        purpose="peer_assessment",
    )
    user_prompt = (
        f"【你的身份】{ _DEFAULT_DISPLAY_NAME[role] }（role={role}）\n"
        f"{PEER_ASSESSMENT_USER_SUFFIX}\n\n"
        f"{context}\n\n"
        "请只输出一个 JSON 对象。"
    )
    messages = [
        {"role": "system", "content": _system_prompt_for_role(role)},
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_ASSESSMENT_MODEL,
            messages=messages,
            temperature=_ASSESSMENT_TEMPERATURE,
            max_tokens=500,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=_ASSESSMENT_EXTRA_BODY,
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[peer-assessment] %s LLM failed: %s", role, e)
        raise LectureAgentError(f"{role} assessment LLM failed: {e}") from e

    return _parse_assessment(
        raw,
        role=role,
        allowed_step_ids=allowed_step_ids,
        student_speech_text=student_speech_text,
        steps=steps,
    )


def generate_peer_assessments(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """并行评估三名同伴，返回 assessments + all_understood。"""

    if not Config.DEEPSEEK_API_KEY or Config.DEEPSEEK_API_KEY == "your_deepseek_api_key_here":
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]
    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))

    common_kwargs = {
        "section_id": section_id,
        "question_id": question_id,
        "question_prompt": question_prompt,
        "student_speech_text": student_speech_text,
        "steps": steps,
        "allowed_step_ids": allowed_step_ids,
        "round_index": safe_round,
        "history": cleaned_history,
    }

    by_role: dict[str, dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {
            pool.submit(_assess_one_peer, role=role, **common_kwargs): role
            for role in _PEER_ROLES
        }
        for fut in as_completed(futures):
            role = futures[fut]
            by_role[role] = fut.result()

    assessments = [by_role[r] for r in _PEER_ROLES if r in by_role]
    if len(assessments) != len(_PEER_ROLES):
        raise LectureAgentError("peer assessments incomplete")

    all_understood = all(a["understood"] for a in assessments)
    status = "completed" if all_understood else "needs_explanation"
    mastery_delta = 1 if all_understood else 0

    logger.info(
        "[peer-assessment] section=%s round=%d understood=%d/3 status=%s",
        section_id,
        safe_round,
        sum(1 for a in assessments if a["understood"]),
        status,
    )

    return {
        "status": status,
        "mastery_delta": mastery_delta,
        "all_understood": all_understood,
        "assessments": assessments,
        "source": "llm",
    }
