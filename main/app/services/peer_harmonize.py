"""同伴评估后处理：限流发言、去重、误解纠正接话编排。"""

from __future__ import annotations

import logging
import re
from typing import Any

from app.services.peer_personas import default_assessment_reason

logger = logging.getLogger(__name__)

_PEER_ORDER = ("xiaoming", "daxiong", "monitor")
_MAX_SPEAKERS_PER_ROUND = 2

# 粗略判断两条 reason 是否在问同一件事（中文短句）。
_OVERLAP_MIN_LEN = 8


def normalize_question_kind(*, role: str, understood: bool, raw_kind: Any) -> str:
    if understood:
        return "none"
    kind = str(raw_kind or "gap").strip().lower()
    if kind not in ("gap", "misconception"):
        kind = "gap"
    if kind == "misconception" and role != "xiaoming":
        kind = "gap"
    return kind


def _step_key(item: dict[str, Any]) -> tuple[str, ...]:
    ids = item.get("highlight_step_ids") or []
    if not isinstance(ids, list):
        return tuple()
    cleaned = tuple(str(x).strip() for x in ids if str(x).strip())
    return cleaned if cleaned else ("__none__",)


def _reason_overlap(a: str, b: str) -> bool:
    ta = re.sub(r"\s+", "", (a or "").strip())
    tb = re.sub(r"\s+", "", (b or "").strip())
    if not ta or not tb:
        return False
    if ta == tb:
        return True
    shorter, longer = (ta, tb) if len(ta) <= len(tb) else (tb, ta)
    if len(shorter) >= _OVERLAP_MIN_LEN and shorter in longer:
        return True
    # 共享较长连续子串
    limit = min(len(shorter), 24)
    for size in range(limit, _OVERLAP_MIN_LEN - 1, -1):
        for i in range(0, len(shorter) - size + 1):
            if shorter[i : i + size] in longer:
                return True
    return False


def _speaker_sort_key(item: dict[str, Any]) -> tuple[int, int]:
    role = str(item.get("role") or "")
    kind = str(item.get("question_kind") or "gap")
    misc_pri = 0 if kind == "misconception" else 1
    role_pri = _PEER_ORDER.index(role) if role in _PEER_ORDER else 99
    return (misc_pri, role_pri)


def harmonize_peer_assessments(
    assessments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """自习室限流：每轮最多 2 人当众发问；同 step / 语义重复只保留优先者。

    被压下去的同伴改为「听懂了」（后台 reason），避免三个评委连珠炮。
    """
    if not assessments:
        return assessments

    working = [dict(a) for a in assessments]
    false_items = [a for a in working if not a.get("understood")]
    if len(false_items) <= 1:
        return working

    false_sorted = sorted(false_items, key=_speaker_sort_key)
    speak_roles: set[str] = set()
    claimed_steps: set[tuple[str, ...]] = set()
    selected: list[dict[str, Any]] = []

    for item in false_sorted:
        if len(selected) >= _MAX_SPEAKERS_PER_ROUND:
            break
        role = str(item.get("role") or "")
        if role in speak_roles:
            continue
        step_key = _step_key(item)
        kind = str(item.get("question_kind") or "gap")
        if step_key in claimed_steps and kind != "misconception":
            continue
        dup = any(
            _reason_overlap(str(item.get("reason") or ""), str(s.get("reason") or ""))
            for s in selected
        )
        if dup and kind != "misconception":
            continue
        selected.append(item)
        speak_roles.add(role)
        claimed_steps.add(step_key)

    if not speak_roles:
        return working

    out: list[dict[str, Any]] = []
    for item in working:
        role = str(item.get("role") or "")
        if not item.get("understood") and role not in speak_roles:
            out.append(
                {
                    **item,
                    "understood": True,
                    "question_kind": "none",
                    "reason": default_assessment_reason(role=role, understood=True),
                }
            )
            logger.info("[peer-harmonize] suppress duplicate speaker role=%s", role)
        else:
            out.append(item)
    return out


def recompute_round_status(assessments: list[dict[str, Any]]) -> dict[str, Any]:
    all_understood = all(bool(a.get("understood")) for a in assessments)
    status = "completed" if all_understood else "needs_explanation"
    mastery_delta = 1 if all_understood else 0
    return {
        "all_understood": all_understood,
        "status": status,
        "mastery_delta": mastery_delta,
    }


def find_misconception_speaker(
    assessments: list[dict[str, Any]],
) -> dict[str, Any] | None:
    for role in _PEER_ORDER:
        for item in assessments:
            if item.get("role") != role:
                continue
            if (
                not item.get("understood")
                and str(item.get("question_kind") or "") == "misconception"
            ):
                return item
    return None
