"""teacher_agent 收束小结：同伴未开口时不应喂 assessment reason 给 LLM。"""

import base64
from types import SimpleNamespace

import pytest

from app.services import teacher_agent
from app.services.teacher_agent import _peer_understood_ack, apply_teacher_completion_gate


def _png_b64(seed: int = 1) -> str:
    return base64.b64encode(b"PNG" + bytes([seed % 256]) * 256).decode("ascii")


def test_peer_understood_ack_omits_reason_text() -> None:
    assessments = [
        {
            "role": "daxiong",
            "display_name": "大雄",
            "understood": True,
            "reason": "我代了个数对上了，这步说得通。",
        },
        {
            "role": "monitor",
            "display_name": "班长",
            "understood": True,
            "reason": "嗯，整体思路我 get 了，特别是合并同类项那步。",
        },
        {
            "role": "xiaoming",
            "display_name": "小明",
            "understood": True,
            "reason": "哦，这步我好像跟上了。",
        },
    ]
    ack = _peer_understood_ack(assessments)
    assert "代入" not in ack
    assert "合并同类项" not in ack
    assert "小明" in ack and "大雄" in ack and "班长" in ack
    assert "未当众发言" in ack


def test_apply_teacher_completion_gate_rejects_wrong_explanation() -> None:
    result = {
        "status": "completed",
        "all_understood": True,
        "mastery_delta": 2,
    }
    summary = {
        "approved": False,
        "text": "不等号方向好像反了，再核对一下被开方数。",
        "method_summary": "",
    }
    gated = apply_teacher_completion_gate(result, summary)
    assert gated["status"] == "needs_explanation"
    assert gated["all_understood"] is False
    assert gated["mastery_delta"] == 0


def test_apply_teacher_completion_gate_rejects_string_false() -> None:
    result = {
        "status": "completed",
        "all_understood": True,
        "mastery_delta": 2,
    }
    summary = {
        "approved": "false",
        "text": "结果不对。",
        "method_summary": "",
    }
    gated = apply_teacher_completion_gate(result, summary)
    assert gated["status"] == "needs_explanation"
    assert gated["all_understood"] is False
    assert gated["mastery_delta"] == 0


def test_apply_teacher_completion_gate_rejects_missing_approved() -> None:
    result = {
        "status": "completed",
        "all_understood": True,
        "mastery_delta": 2,
    }
    summary = {"text": "字段缺失时不能放行。"}
    gated = apply_teacher_completion_gate(result, summary)
    assert gated["status"] == "needs_explanation"
    assert gated["all_understood"] is False
    assert gated["mastery_delta"] == 0


def test_apply_teacher_completion_gate_passes_when_approved() -> None:
    result = {
        "status": "completed",
        "all_understood": True,
        "mastery_delta": 2,
    }
    summary = {"approved": True, "text": "讲清楚了。"}
    gated = apply_teacher_completion_gate(result, summary)
    assert gated["status"] == "completed"
    assert gated["all_understood"] is True
    assert gated["mastery_delta"] == 2


def test_teacher_hint_routes_to_kimi_vision_when_image_available(monkeypatch) -> None:
    """第十二轮第五轮：李老师有图时优先走 Kimi-K2.6 multimodal。"""
    captured: dict[str, object] = {}

    class _FakeCompletions:
        def create(self, **kwargs):  # noqa: ANN003
            captured.update(kwargs)
            return SimpleNamespace(
                choices=[
                    SimpleNamespace(
                        message=SimpleNamespace(
                            content='{"text":"先看条件再算","highlightStepIds":["board"]}',
                        )
                    )
                ]
            )

    class _FakeClient:
        chat = SimpleNamespace(completions=_FakeCompletions())

        def with_options(self, **_kwargs):  # noqa: ANN003
            return self

    monkeypatch.setattr(
        "app.services.teacher_agent.kimi_dashscope_api_key_configured",
        lambda: True,
    )
    monkeypatch.setattr(
        "app.services.teacher_agent.kimi_dashscope_client",
        _FakeClient(),
    )
    monkeypatch.setattr(
        "app.services.teacher_agent._TEACHER_VISION_MODEL",
        "kimi-k2.6",
    )

    result = teacher_agent.generate_teacher_hint(
        section_id="pep-g8-down-s16-1",
        question_id="q1",
        question_prompt="化简",
        student_speech_text="我有点卡住",
        steps=[{"stepId": "board", "strokeCount": 3, "latex": "", "plainText": ""}],
        round_index=1,
        history=[],
        current_board_image_base64=_png_b64(1),
    )

    assert captured["model"] == "kimi-k2.6"
    user_content = captured["messages"][1]["content"]
    # multimodal 路径 user.content 必须是 list（含 image_url 项）
    assert isinstance(user_content, list)
    assert any(c.get("type") == "image_url" for c in user_content)
    assert result["role"] == "teacher"
    assert result["text"]


def test_teacher_summary_falls_back_to_deepseek_when_kimi_missing(monkeypatch) -> None:
    """KIMI_DASHSCOPE_KEY 未配置时，李老师收束兜底到 DeepSeek 文本。"""
    captured: dict[str, object] = {}

    class _FakeCompletions:
        def create(self, **kwargs):  # noqa: ANN003
            captured.update(kwargs)
            return SimpleNamespace(
                choices=[
                    SimpleNamespace(
                        message=SimpleNamespace(
                            content='{"approved":true,"text":"讲清楚了",'
                            '"methodSummary":"先化简再合并","highlightStepIds":["board"]}',
                        )
                    )
                ]
            )

    class _FakeClient:
        chat = SimpleNamespace(completions=_FakeCompletions())

        def with_options(self, **_kwargs):  # noqa: ANN003
            return self

    monkeypatch.setattr(
        "app.services.teacher_agent.kimi_dashscope_api_key_configured",
        lambda: False,
    )
    monkeypatch.setattr(
        "app.services.teacher_agent.deepseek_api_key_configured",
        lambda: True,
    )
    monkeypatch.setattr(
        "app.services.teacher_agent.deepseek_client",
        _FakeClient(),
    )

    result = teacher_agent.generate_teacher_summary(
        section_id="pep-g8-down-s16-1",
        question_id="q1",
        question_prompt="化简",
        student_speech_text="我先化简再合并",
        steps=[{"stepId": "board", "strokeCount": 5}],
        round_index=2,
        history=[],
        peer_assessments=[
            {"role": "xiaoming", "display_name": "小明", "understood": True},
            {"role": "daxiong", "display_name": "大雄", "understood": True},
            {"role": "monitor", "display_name": "班长", "understood": True},
        ],
        current_board_image_base64=_png_b64(2),
    )

    # 走的是 DeepSeek 文本：messages.user.content 是 str
    user_content = captured["messages"][1]["content"]
    assert isinstance(user_content, str)
    assert result["approved"] is True
    assert result["text"]


def test_teacher_hint_raises_when_no_key_configured(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.teacher_agent.kimi_dashscope_api_key_configured",
        lambda: False,
    )
    monkeypatch.setattr(
        "app.services.teacher_agent.deepseek_api_key_configured",
        lambda: False,
    )
    with pytest.raises(Exception):
        teacher_agent.generate_teacher_hint(
            section_id="pep-g8-down-s16-1",
            question_id="q1",
            question_prompt="化简",
            student_speech_text="",
            steps=[{"stepId": "board", "strokeCount": 1}],
            round_index=1,
            history=[],
        )
