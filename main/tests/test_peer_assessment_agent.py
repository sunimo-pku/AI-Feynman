from __future__ import annotations

import base64
from types import SimpleNamespace

import pytest

from app.services import peer_assessment_agent
from app.services.lecture_agent import LectureAgentError


def _png_b64(seed: int) -> str:
    """生成一个看起来像 PNG 的小 base64 字符串（不需要真合法，只要长度过下限）。"""
    raw = b"PNG" + bytes([seed % 256]) * 256
    return base64.b64encode(raw).decode("ascii")


def test_generate_peer_assessments_requires_key(monkeypatch) -> None:
    monkeypatch.setattr("app.services.peer_assessment_agent.Config.DEEPSEEK_API_KEY", "")
    monkeypatch.setattr("app.services.peer_assessment_agent.Config.ALIYUN_API_KEY", "")
    with pytest.raises(LectureAgentError):
        peer_assessment_agent.generate_peer_assessments(
            section_id="pep-g8-down-s16-1",
            question_id="q",
            question_prompt="化简",
            student_speech_text="",
            steps=[{"stepId": "step_1", "strokeCount": 1}],
        )


def test_parse_assessment_string_false_is_false() -> None:
    parsed = peer_assessment_agent._parse_assessment(
        '{"understood":"false","questionKind":"gap","reason":"我这里没听懂","highlightStepIds":["step_1"]}',
        role="xiaoming",
        allowed_step_ids=["step_1"],
        student_speech_text="",
        steps=[{"stepId": "step_1", "strokeCount": 1}],
    )
    assert parsed["understood"] is False
    assert parsed["question_kind"] == "gap"


def test_parse_assessment_rejects_missing_understood() -> None:
    with pytest.raises(LectureAgentError):
        peer_assessment_agent._parse_assessment(
            '{"questionKind":"gap","reason":"我这里没听懂","highlightStepIds":["step_1"]}',
            role="xiaoming",
            allowed_step_ids=["step_1"],
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
            "question_kind": "none" if understood else "gap",
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


def test_collect_board_images_orders_history_then_current() -> None:
    prior_boards = [
        {
            "round_index": 1,
            "board_image_base64": _png_b64(1),
        },
        {
            "round_index": 2,
            "board_image_base64": _png_b64(2),
        },
    ]
    collected = peer_assessment_agent._collect_board_images(
        prior_boards,
        _png_b64(99),
        current_round=3,
    )
    assert [item["round"] for item in collected] == [1, 2, 3]
    assert [item["is_current"] for item in collected] == [False, False, True]


def test_collect_board_images_skips_empty_and_caps_count() -> None:
    prior_boards = [
        {"round_index": i, "board_image_base64": _png_b64(i)}
        for i in range(1, 8)
    ]
    prior_boards.append({"round_index": 8, "board_image_base64": ""})  # 空图丢掉
    collected = peer_assessment_agent._collect_board_images(
        prior_boards,
        _png_b64(99),
        current_round=9,
    )
    # 当前轮永远保留 + 最近 3 轮 = 4
    assert len(collected) == peer_assessment_agent._VISION_MAX_IMAGES
    assert collected[-1]["is_current"] is True
    assert collected[-1]["round"] == 9
    assert [item["round"] for item in collected[:-1]] == [5, 6, 7]


def test_collect_board_images_filters_oversize_image() -> None:
    oversize = "x" * (peer_assessment_agent._VISION_MAX_IMAGE_B64_LEN + 1)
    collected = peer_assessment_agent._collect_board_images(
        [{"round_index": 1, "board_image_base64": oversize}],
        "",
        current_round=2,
    )
    assert collected == []


def test_build_vision_user_content_inserts_round_labels() -> None:
    images = [
        {"round": 1, "image_base64": _png_b64(1), "is_current": False},
        {"round": 2, "image_base64": _png_b64(2), "is_current": True},
    ]
    content = peer_assessment_agent._build_vision_user_content(
        text_prompt="评估请求文本",
        board_images=images,
    )
    # 顺序：label1, image1, label2, image2, text_prompt
    assert len(content) == 5
    assert content[0]["type"] == "text" and "第 1 轮" in content[0]["text"]
    assert "历史整板照片" in content[0]["text"]
    assert content[1]["type"] == "image_url"
    assert content[1]["image_url"]["url"].startswith("data:image/png;base64,")
    assert content[2]["type"] == "text" and "第 2 轮" in content[2]["text"]
    assert "本轮整板照片" in content[2]["text"]
    assert content[3]["type"] == "image_url"
    assert content[4]["type"] == "text" and content[4]["text"] == "评估请求文本"


def test_assess_one_peer_uses_vision_when_images_available(monkeypatch) -> None:
    captured: dict[str, object] = {}

    class _FakeChoice:
        def __init__(self, content: str) -> None:
            self.message = SimpleNamespace(content=content)

    class _FakeResp:
        def __init__(self, content: str) -> None:
            self.choices = [_FakeChoice(content)]

    class _FakeCompletions:
        def create(self, **kwargs):  # noqa: ANN003
            captured.update(kwargs)
            return _FakeResp(
                '{"understood": false, "questionKind": "gap", '
                '"reason": "白板上第二轮还是同一个答案", '
                '"highlightStepIds": ["board"]}'
            )

    class _FakeChat:
        completions = _FakeCompletions()

    class _FakeClient:
        chat = _FakeChat()

        def with_options(self, **_kwargs):  # noqa: ANN003
            return self

    monkeypatch.setattr(
        "app.services.peer_assessment_agent._vision_client",
        lambda: _FakeClient(),
    )
    monkeypatch.setattr(
        "app.services.peer_assessment_agent.Config.QWEN_VL_MODEL",
        "qwen-vl-max",
    )

    result = peer_assessment_agent.assess_one_peer(
        role="xiaoming",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="化简",
        student_speech_text="我把根号 12 拆成 2 根号 3",
        steps=[{"stepId": "board", "strokeCount": 6, "latex": "", "plainText": ""}],
        allowed_step_ids=["board"],
        round_index=2,
        history=[
            {"role": "student", "displayName": "我", "text": "上一轮口述"},
            {"role": "xiaoming", "displayName": "小明", "text": "你为什么这么拆？"},
        ],
        round_board_snapshots=[
            {
                "round_index": 1,
                "board_latex": r"\sqrt{12}=2\sqrt{3}",
                "board_plain_text": "",
                "stroke_count": 4,
                "board_image_base64": _png_b64(1),
            },
        ],
        current_board_image_base64=_png_b64(2),
    )

    # 走了 Qwen-VL 路径：model = QWEN_VL_MODEL，messages.user.content 是 list
    assert captured["model"] == "qwen-vl-max"
    messages = captured["messages"]
    assert len(messages) == 2
    user_content = messages[1]["content"]
    assert isinstance(user_content, list)
    image_items = [c for c in user_content if c["type"] == "image_url"]
    assert len(image_items) == 2  # 上一轮 + 本轮
    text_items = [c for c in user_content if c["type"] == "text"]
    assert any("第 1 轮" in t["text"] for t in text_items)
    assert any("第 2 轮" in t["text"] for t in text_items)
    # 解析仍然走原解析器
    assert result["role"] == "xiaoming"
    assert result["understood"] is False
    assert result["question_kind"] == "gap"


def test_assess_one_peer_falls_back_to_text_when_no_aliyun_key(monkeypatch) -> None:
    captured: dict[str, object] = {}

    class _FakeChoice:
        def __init__(self, content: str) -> None:
            self.message = SimpleNamespace(content=content)

    class _FakeResp:
        def __init__(self, content: str) -> None:
            self.choices = [_FakeChoice(content)]

    class _FakeCompletions:
        def create(self, **kwargs):  # noqa: ANN003
            captured.update(kwargs)
            return _FakeResp(
                '{"understood": true, "questionKind": "none", '
                '"reason": "跟上了", "highlightStepIds": ["board"]}'
            )

    class _FakeChat:
        completions = _FakeCompletions()

    class _FakeClient:
        chat = _FakeChat()

        def with_options(self, **_kwargs):  # noqa: ANN003
            return self

    monkeypatch.setattr(
        "app.services.peer_assessment_agent._vision_client",
        lambda: None,
    )
    monkeypatch.setattr(
        "app.services.peer_assessment_agent.deepseek_client",
        _FakeClient(),
    )

    result = peer_assessment_agent.assess_one_peer(
        role="daxiong",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="化简",
        student_speech_text="",
        steps=[{"stepId": "board", "strokeCount": 2}],
        allowed_step_ids=["board"],
        round_index=1,
        history=[],
        current_board_image_base64=_png_b64(7),  # 给了图也走 text，因为没有 vision client
    )

    # 纯文本 messages.user.content 是字符串
    user_content = captured["messages"][1]["content"]
    assert isinstance(user_content, str)
    assert result["understood"] is True


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
