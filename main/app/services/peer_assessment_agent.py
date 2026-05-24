"""同伴听课评估：小明 / 大雄 / 班长各 1 次独立 LLM 调用。

P1：学生每提交一轮讲解，三人并行评估「听懂 / 没听懂」及理由。
全员听懂时由 `teacher_agent.generate_teacher_summary` 收束（在路由层触发）。
"""

from __future__ import annotations

import json
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from app.config import Config
from app.services.kimi import deepseek_api_key_configured, deepseek_client, deepseek_thinking_disabled_extra_body
from app.services.lecture_agent import (
    LectureAgentError,
    _DEFAULT_DISPLAY_NAME,
    _PEER_ROLES,
    _build_user_prompt,
    _sanitize_history,
    _sanitize_round_board_snapshots,
    _strip_markdown_fence,
)
from app.services.peer_harmonize import (
    find_misconception_speaker,
    harmonize_peer_assessments,
    normalize_question_kind,
    recompute_round_status,
)
from app.services.question_bank import resolve_standard_answer
from app.services.peer_personas import (
    PEER_ASSESSMENT_USER_SUFFIX,
    build_monitor_misconception_correction_system_prompt,
    build_peer_assessment_system_prompt,
    default_assessment_reason,
)

logger = logging.getLogger(__name__)

_ASSESSMENT_MODEL = Config.DEEPSEEK_MODEL
_ASSESSMENT_TEMPERATURE = 0.45
_ASSESSMENT_EXTRA_BODY: dict[str, Any] = {}  # 见 deepseek_thinking_disabled_extra_body()
_LLM_TIMEOUT_SECONDS = 5.0
_MAX_REASON_LEN = 220
# 与 lecture_agent._HISTORY_KEEP_LAST 对齐（约 10 轮完整闭环）。
# 不再在 peer 路径做更紧的二次裁切——同伴能看到的跨轮记忆与全局一致，
# 包括前几轮学生 ASR 全文、三人判断与老师收束。如果未来 prompt 长度
# 真的成为瓶颈，再考虑按 roundIndex（而不是按条数）裁切。
_PEER_HISTORY_KEEP = 60

# 「你说『…』」类表述：引号内必须出现在本轮 student_speech_text 里。
_SPEECH_QUOTE_RE = re.compile(
    r"(?:你说|你刚才说|你刚刚说)[「『\"']([^」』\"']{2,})[」』\"']"
)


def _parse_bool_field(value: Any, *, field: str, role: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    raise LectureAgentError(f"{role} assessment {field} must be boolean")


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

    understood = _parse_bool_field(
        payload.get("understood"),
        field="understood",
        role=role,
    )
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

    question_kind = normalize_question_kind(
        role=role,
        understood=understood,
        raw_kind=payload.get("questionKind") or payload.get("question_kind"),
    )

    return {
        "role": role,
        "display_name": _DEFAULT_DISPLAY_NAME[role],
        "understood": understood,
        "reason": reason,
        "highlight_step_ids": highlight,
        "question_kind": question_kind,
    }


def assess_one_peer(
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
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """单次 LLM 评估一名同伴（供 live session 并行 + 增量推送）。"""
    return _assess_one_peer(
        role=role,
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=history,
        standard_answer=standard_answer,
        round_board_snapshots=round_board_snapshots,
    )


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
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    cleaned_history = _sanitize_history(history)
    if len(cleaned_history) > _PEER_HISTORY_KEEP:
        cleaned_history = cleaned_history[-_PEER_HISTORY_KEEP:]
    std = (standard_answer or "").strip() or resolve_standard_answer(
        question_id=question_id,
    )
    prior_boards = _sanitize_round_board_snapshots(
        round_board_snapshots,
        current_round=round_index,
    )
    context = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=cleaned_history,
        purpose="peer_assessment",
        standard_answer=std,
        round_board_snapshots=prior_boards,
        assessing_role=role,
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
    t0 = time.monotonic()
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_ASSESSMENT_MODEL,
            messages=messages,
            temperature=_ASSESSMENT_TEMPERATURE,
            max_tokens=280,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=deepseek_thinking_disabled_extra_body(),
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[peer-assessment] %s LLM failed: %s", role, e)
        raise LectureAgentError(f"{role} assessment LLM failed: {e}") from e

    parsed = _parse_assessment(
        raw,
        role=role,
        allowed_step_ids=allowed_step_ids,
        student_speech_text=student_speech_text,
        steps=steps,
    )
    logger.info(
        "[peer-assessment] %s ms=%.0f understood=%s kind=%s",
        role,
        (time.monotonic() - t0) * 1000,
        parsed.get("understood"),
        parsed.get("question_kind"),
    )
    return parsed


def _generate_monitor_misconception_correction(
    *,
    xiaoming_item: dict[str, Any],
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
) -> dict[str, Any] | None:
    """小明误解型提问后，班长接一句帮腔纠偏（可选 LLM）。"""
    if not deepseek_api_key_configured():
        return None

    context = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=[],
        purpose="peer_assessment",
    )
    user_prompt = (
        f"【小明刚才的误解型提问】\n{xiaoming_item.get('reason', '')}\n\n"
        f"{context}\n\n"
        "请输出班长纠偏 JSON。"
    )
    messages = [
        {
            "role": "system",
            "content": build_monitor_misconception_correction_system_prompt(),
        },
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_ASSESSMENT_MODEL,
            messages=messages,
            temperature=0.35,
            max_tokens=200,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=deepseek_thinking_disabled_extra_body(),
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.warning("[peer-assessment] monitor correction LLM failed: %s", e)
        return None

    cleaned = _strip_markdown_fence(raw or "")
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    text = str(payload.get("text") or "").strip()
    if not text:
        return None
    if len(text) > _MAX_REASON_LEN:
        text = text[:_MAX_REASON_LEN].rstrip() + "…"

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
        "turn_id": "reply_monitor_misconception",
        "role": "monitor",
        "display_name": _DEFAULT_DISPLAY_NAME["monitor"],
        "text": text,
        "highlight_step_ids": highlight,
    }


def finalize_peer_assessment_round(
    *,
    assessments: list[dict[str, Any]],
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
) -> dict[str, Any]:
    harmonized = harmonize_peer_assessments(assessments)
    status_bits = recompute_round_status(harmonized)

    peer_replies: list[dict[str, Any]] = []
    misc = find_misconception_speaker(harmonized)
    if misc is not None:
        correction = _generate_monitor_misconception_correction(
            xiaoming_item=misc,
            section_id=section_id,
            question_id=question_id,
            question_prompt=question_prompt,
            student_speech_text=student_speech_text,
            steps=steps,
            allowed_step_ids=allowed_step_ids,
            round_index=round_index,
        )
        if correction is not None:
            peer_replies.append(correction)

    logger.info(
        "[peer-assessment] finalize round=%d speakers=%d replies=%d status=%s",
        round_index,
        sum(1 for a in harmonized if not a.get("understood")),
        len(peer_replies),
        status_bits["status"],
    )

    return {
        **status_bits,
        "assessments": harmonized,
        "peer_replies": peer_replies,
        "source": "llm",
    }


def generate_peer_assessments(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """并行评估三名同伴，返回 assessments + all_understood。"""

    if not deepseek_api_key_configured():
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]
    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))
    prior_boards = _sanitize_round_board_snapshots(
        round_board_snapshots,
        current_round=safe_round,
    )
    std = resolve_standard_answer(
        question_id=question_id,
        client_answer=standard_answer,
    )

    common_kwargs = {
        "section_id": section_id,
        "question_id": question_id,
        "question_prompt": question_prompt,
        "student_speech_text": student_speech_text,
        "steps": steps,
        "allowed_step_ids": allowed_step_ids,
        "round_index": safe_round,
        "history": cleaned_history,
        "standard_answer": std,
        "round_board_snapshots": prior_boards,
    }

    by_role: dict[str, dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {
            pool.submit(assess_one_peer, role=role, **common_kwargs): role
            for role in _PEER_ROLES
        }
        for fut in as_completed(futures):
            role = futures[fut]
            by_role[role] = fut.result()

    assessments = [by_role[r] for r in _PEER_ROLES if r in by_role]
    if len(assessments) != len(_PEER_ROLES):
        raise LectureAgentError("peer assessments incomplete")

    finalized = finalize_peer_assessment_round(
        assessments=assessments,
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
    )

    logger.info(
        "[peer-assessment] section=%s round=%d understood=%d/3 status=%s",
        section_id,
        safe_round,
        sum(1 for a in finalized["assessments"] if a["understood"]),
        finalized["status"],
    )

    return finalized
