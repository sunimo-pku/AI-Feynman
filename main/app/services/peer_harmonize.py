"""同伴评估后处理：标准化 questionKind、计算轮次状态、误解纠正接话编排。"""

from __future__ import annotations

from typing import Any

_PEER_ORDER = ("xiaoming", "daxiong", "monitor")


def normalize_question_kind(*, role: str, understood: bool, raw_kind: Any) -> str:
    if understood:
        return "none"
    kind = str(raw_kind or "gap").strip().lower()
    if kind not in ("gap", "misconception"):
        kind = "gap"
    if kind == "misconception" and role != "xiaoming":
        kind = "gap"
    return kind


def harmonize_peer_assessments(
    assessments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """保留三名同伴的真实判断，不再限流或把异议改成听懂。"""
    return [dict(a) for a in assessments]


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
