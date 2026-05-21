from __future__ import annotations

import pytest

from app.services import lecture_agent_stream
from app.services import lecture_agent


def test_stream_requires_deepseek_key(monkeypatch) -> None:
    monkeypatch.setattr("app.services.lecture_agent_stream.Config.DEEPSEEK_API_KEY", "")
    with pytest.raises(lecture_agent.LectureAgentError):
        list(lecture_agent_stream.generate_turn_events(
            section_id="pep-g8-down-s16-3",
            question_id="q",
            question_prompt="化简",
            student_speech_text="",
            steps=[{"stepId": "step_1", "strokeCount": 1}],
        ))


def test_parse_ndjson_line_filters_highlight() -> None:
    event = lecture_agent_stream._parse_line(
        '{"type":"turn_start","turnId":"t1","role":"xiaoming","displayName":"小明","highlightStepIds":["bad"]}',
        ["step_1"],
    )
    assert event is not None
    assert event["highlightStepIds"] == ["step_1"]


def test_non_radical_empty_input_prompt_is_generic() -> None:
    prompt = lecture_agent._build_user_prompt(
        section_id="pep-g9-up-s22-1",
        question_id="q-fn",
        question_prompt="已知二次函数 y=x^2-2x，说明图像顶点和对称轴。",
        student_speech_text="",
        steps=[{"stepId": "step_1", "strokeCount": 1}],
        allowed_step_ids=["step_1"],
        round_index=1,
        history=[],
    )
    assert "判断本题所属领域" in prompt
    assert "二次根式" not in prompt
    assert "函数关系" in prompt


def test_lecture_agent_requires_deepseek_key(monkeypatch) -> None:
    monkeypatch.setattr("app.services.lecture_agent.Config.DEEPSEEK_API_KEY", "")
    with pytest.raises(lecture_agent.LectureAgentError):
        lecture_agent.generate_lecture_turns(
            section_id="pep-g8-down-s16-1",
            question_id="q-s16-1-001",
            question_prompt=r"判断 $\sqrt{2x-6}$ 在实数范围内有意义时，$x$ 的取值范围。",
            student_speech_text="",
            steps=[{"stepId": "step_1", "strokeCount": 1}],
        )


def test_lecture_agent_uses_deepseek_non_thinking(monkeypatch) -> None:
    captured: dict = {}

    class FakeMessage:
        content = (
            '{"status":"needs_explanation","masteryDelta":0,'
            '"turns":[{"role":"teacher","displayName":"李老师","text":"请解释这一步依据。",'
            '"highlightStepIds":["step_1"]}]}'
        )

    class FakeChoice:
        message = FakeMessage()

    class FakeResponse:
        choices = [FakeChoice()]

    class FakeCompletions:
        def create(self, **kwargs):
            captured.update(kwargs)
            return FakeResponse()

    class FakeChat:
        completions = FakeCompletions()

    class FakeClient:
        chat = FakeChat()

        def with_options(self, **kwargs):
            captured["with_options"] = kwargs
            return self

    monkeypatch.setattr("app.services.lecture_agent.Config.DEEPSEEK_API_KEY", "key")
    monkeypatch.setattr("app.services.lecture_agent.deepseek_client", FakeClient())
    payload = lecture_agent.generate_lecture_turns(
        section_id="pep-g9-up-s22-1",
        question_id="q",
        question_prompt="已知二次函数 y=x^2-2x，说明顶点。",
        student_speech_text="",
        steps=[{"stepId": "step_1", "strokeCount": 1}],
    )

    assert payload["source"] == "llm"
    assert captured["model"] == "deepseek-v4-flash"
    assert captured["extra_body"] == {"thinking": {"type": "disabled"}}


def test_stream_agent_uses_deepseek_non_thinking(monkeypatch) -> None:
    captured: dict = {}

    class FakeDelta:
        content = '{"type":"round_meta","status":"needs_explanation","masteryDelta":0}\n'

    class FakeChoice:
        delta = FakeDelta()

    class FakeChunk:
        choices = [FakeChoice()]

    class FakeCompletions:
        def create(self, **kwargs):
            captured.update(kwargs)
            return iter([FakeChunk()])

    class FakeChat:
        completions = FakeCompletions()

    class FakeClient:
        chat = FakeChat()

        def with_options(self, **kwargs):
            captured["with_options"] = kwargs
            return self

    monkeypatch.setattr("app.services.lecture_agent_stream.Config.DEEPSEEK_API_KEY", "key")
    monkeypatch.setattr("app.services.lecture_agent_stream.deepseek_client", FakeClient())
    events = list(lecture_agent_stream.generate_turn_events(
        section_id="pep-g9-up-s22-1",
        question_id="q",
        question_prompt="已知二次函数 y=x^2-2x，说明顶点。",
        student_speech_text="",
        steps=[{"stepId": "step_1", "strokeCount": 1}],
    ))

    assert events[-1]["type"] == "round_meta"
    assert captured["model"] == "deepseek-v4-flash"
    assert captured["stream"] is True
    assert captured["timeout"] == 2.0
    assert captured["extra_body"] == {"thinking": {"type": "disabled"}}
