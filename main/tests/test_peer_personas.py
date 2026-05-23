from __future__ import annotations

from app.services.peer_personas import (
    build_lecture_director_system_prompt,
    build_peer_assessment_system_prompt,
    default_assessment_reason,
)


def test_peer_assessment_prompts_sound_like_classmates_not_tutors() -> None:
    xiaoming = build_peer_assessment_system_prompt("xiaoming")
    daxiong = build_peer_assessment_system_prompt("daxiong")
    assert "同班" in xiaoming or "同学" in xiaoming
    assert "禁止" in xiaoming
    assert "misconception" in xiaoming
    assert "misconception" not in daxiong or "禁止" in daxiong
    assert "跟不上了" in xiaoming or "卡" in xiaoming
    assert "API" not in xiaoming


def test_monitor_prompt_requires_hard_math_check_before_approval() -> None:
    monitor = build_peer_assessment_system_prompt("monitor")
    assert "最后检查" in monitor
    assert "独立解一遍题" in monitor
    assert "答案完全正确才放行" in monitor
    assert "听起来合理" in monitor


def test_lecture_director_prompt_has_group_discussion_scene() -> None:
    prompt = build_lecture_director_system_prompt()
    assert "小组" in prompt
    assert "批作业" in prompt
    assert "xiaoming" in prompt


def test_default_assessment_reason_varies_by_role() -> None:
    assert default_assessment_reason(role="xiaoming", understood=False) != (
        default_assessment_reason(role="daxiong", understood=False)
    )
    assert len(default_assessment_reason(role="daxiong", understood=True)) <= 12
