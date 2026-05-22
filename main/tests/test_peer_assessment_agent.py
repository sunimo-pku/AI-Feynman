from __future__ import annotations

import pytest

from app.services import peer_assessment_agent
from app.services.lecture_agent import LectureAgentError


def test_generate_peer_assessments_requires_key(monkeypatch) -> None:
    monkeypatch.setattr("app.services.peer_assessment_agent.Config.DEEPSEEK_API_KEY", "")
    with pytest.raises(LectureAgentError):
        peer_assessment_agent.generate_peer_assessments(
            section_id="pep-g8-down-s16-1",
            question_id="q",
            question_prompt="化简",
            student_speech_text="",
            steps=[{"stepId": "step_1", "strokeCount": 1}],
        )


def test_generate_peer_assessments_parallel(monkeypatch) -> None:
    calls: list[str] = []

    def fake_assess_one(*, role: str, **kwargs):  # noqa: ANN003
        calls.append(role)
        understood = role != "daxiong"
        return {
            "role": role,
            "display_name": {"xiaoming": "小明", "daxiong": "大雄", "monitor": "班长"}[role],
            "understood": understood,
            "reason": "ok" if understood else "符号还没讲清",
            "highlight_step_ids": ["step_1"],
        }

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.Config.DEEPSEEK_API_KEY",
        "key",
    )
    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        fake_assess_one,
    )
    result = peer_assessment_agent.generate_peer_assessments(
        section_id="pep-g8-down-s16-1",
        question_id="q",
        question_prompt="化简",
        student_speech_text="根号12",
        steps=[{"stepId": "step_1", "strokeCount": 1, "plainText": "2根号3"}],
        round_index=1,
    )

    assert set(calls) == {"xiaoming", "daxiong", "monitor"}
    assert result["all_understood"] is False
    assert result["status"] == "needs_explanation"
    assert len(result["assessments"]) == 3


def test_all_understood_sets_completed(monkeypatch) -> None:
    def fake_assess_one(*, role: str, **kwargs):  # noqa: ANN003
        return {
            "role": role,
            "display_name": role,
            "understood": True,
            "reason": "听懂了",
            "highlight_step_ids": ["step_1"],
        }

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.Config.DEEPSEEK_API_KEY",
        "key",
    )
    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        fake_assess_one,
    )
    result = peer_assessment_agent.generate_peer_assessments(
        section_id="pep-g8-down-s16-1",
        question_id="q",
        question_prompt="化简",
        student_speech_text="",
        steps=[{"stepId": "step_1", "strokeCount": 1}],
    )
    assert result["all_understood"] is True
    assert result["status"] == "completed"
    assert result["mastery_delta"] == 1
