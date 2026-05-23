from __future__ import annotations

from app.services.peer_harmonize import (
    find_misconception_speaker,
    harmonize_peer_assessments,
    normalize_question_kind,
    recompute_round_status,
)


def _item(
    role: str,
    *,
    understood: bool,
    reason: str,
    step: str = "step_1",
    kind: str = "gap",
) -> dict:
    return {
        "role": role,
        "display_name": role,
        "understood": understood,
        "reason": reason,
        "highlight_step_ids": [step],
        "question_kind": kind if not understood else "none",
    }


def test_normalize_question_kind_only_xiaoming_misconception() -> None:
    assert (
        normalize_question_kind(role="xiaoming", understood=False, raw_kind="misconception")
        == "misconception"
    )
    assert (
        normalize_question_kind(role="daxiong", understood=False, raw_kind="misconception")
        == "gap"
    )


def test_harmonize_limits_speakers_and_dedupes_same_step() -> None:
    raw = [
        _item("xiaoming", understood=False, reason="这一步为啥能直接这样写啊"),
        _item("daxiong", understood=False, reason="我代进去好像不对，中间是不是跳步了"),
        _item("monitor", understood=False, reason="这一步为啥能直接这样写啊我也想知道"),
    ]
    out = harmonize_peer_assessments(raw)
    speakers = [a for a in out if not a["understood"]]
    assert len(speakers) <= 2
    assert any(a["role"] == "xiaoming" for a in speakers)


def test_harmonize_keeps_misconception_with_gap_on_different_angle() -> None:
    raw = [
        _item(
            "xiaoming",
            understood=False,
            reason="是不是可以把根号拆开相加？",
            kind="misconception",
        ),
        _item(
            "daxiong",
            understood=False,
            reason="我代 x=1 算好像对不上",
            step="step_2",
        ),
        _item("monitor", understood=True, reason="跟上了"),
    ]
    out = harmonize_peer_assessments(raw)
    speakers = [a for a in out if not a["understood"]]
    assert len(speakers) == 2
    assert find_misconception_speaker(out) is not None


def test_recompute_round_status_after_harmonize_all_understood() -> None:
    raw = [
        _item("xiaoming", understood=False, reason="同一句重复追问"),
        _item("daxiong", understood=False, reason="同一句重复追问"),
        _item("monitor", understood=True, reason="懂了"),
    ]
    out = harmonize_peer_assessments(raw)
    bits = recompute_round_status(out)
    assert bits["all_understood"] is False or sum(1 for a in out if not a["understood"]) <= 1
