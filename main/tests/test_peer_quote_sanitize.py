from __future__ import annotations

from app.services.peer_assessment_agent import _sanitize_reason_quotes
from app.services.tts_text import plain_text_for_tts


def test_sanitize_reason_quotes_keeps_valid_speech() -> None:
    reason = "你说「根号12」这里还没讲清定义域。"
    out = _sanitize_reason_quotes(
        reason,
        student_speech_text="我先化简根号12",
        steps=[{"plainText": "2根号3"}],
    )
    assert "根号12" in out


def test_sanitize_reason_quotes_rewrites_step_only_quote() -> None:
    reason = "你说「2根号3」是怎么来的？"
    out = _sanitize_reason_quotes(
        reason,
        student_speech_text="",
        steps=[{"plainText": "2根号3", "latex": r"2\sqrt{3}"}],
    )
    assert "你写的「2根号3」" in out
    assert "你说" not in out


def test_plain_text_for_tts_strips_latex() -> None:
    assert "sqrt" not in plain_text_for_tts(r"化简 $\sqrt{12}=2\sqrt{3}$")
