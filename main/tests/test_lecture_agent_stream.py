from __future__ import annotations

from app.services import lecture_agent_stream


def test_stream_fallback_event_order(monkeypatch) -> None:
    monkeypatch.setattr("app.services.lecture_agent_stream.Config.KIMI_API_KEY", "")
    events = list(
        lecture_agent_stream.generate_turn_events(
            section_id="pep-g8-down-s16-3",
            question_id="q",
            question_prompt="化简",
            student_speech_text="",
            steps=[{"stepId": "step_1", "strokeCount": 1}],
        )
    )
    assert [e["type"] for e in events[:3]] == ["turn_start", "delta", "turn_done"]
    assert events[-1]["type"] == "round_meta"
    assert events[-1]["source"] == "stream_fallback"


def test_parse_ndjson_line_filters_highlight() -> None:
    event = lecture_agent_stream._parse_line(
        '{"type":"turn_start","turnId":"t1","role":"xiaoming","displayName":"小明","highlightStepIds":["bad"]}',
        ["step_1"],
    )
    assert event is not None
    assert event["highlightStepIds"] == ["step_1"]
