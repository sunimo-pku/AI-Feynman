import base64

from app.services import qwen_vision


class _FakeMessage:
    content = '{"latex":"x=1","plainText":"x 等于 1","confidence":0.8}'


class _FakeChoice:
    message = _FakeMessage()


class _FakeResponse:
    choices = [_FakeChoice()]


class _FakeCompletions:
    def __init__(self, captured: dict):
        self._captured = captured

    def create(self, **kwargs):
        self._captured.update(kwargs)
        return _FakeResponse()


class _FakeChat:
    def __init__(self, captured: dict):
        self.completions = _FakeCompletions(captured)


class _FakeClient:
    def __init__(self, captured: dict):
        self.chat = _FakeChat(captured)

    def with_options(self, **_kwargs):
        return self


def test_ink_board_prompt_uses_question_context_only_for_disambiguation(
    monkeypatch,
) -> None:
    captured: dict = {}
    monkeypatch.setattr(qwen_vision.Config, "ALIYUN_API_KEY", "ci-key")
    monkeypatch.setattr(
        qwen_vision,
        "OpenAI",
        lambda **_kwargs: _FakeClient(captured),
    )

    result = qwen_vision.recognize_ink_board(
        image_base64=base64.b64encode(b"not-a-real-png" * 8).decode(),
        section_id="pep-g8-down-s16-1",
        question_id="q1",
        question_prompt=r"化简：$\sqrt{12}$",
        section_label="二次根式",
        knowledge_tags=["化简", "因式分解"],
    )

    text_parts = captured["messages"][0]["content"]
    prompt = text_parts[1]["text"]
    assert result["source"] == "qwen_vl"
    assert r"化简：$\sqrt{12}$" in prompt
    assert "当前小节：二次根式" in prompt
    assert "知识点：化简、因式分解" in prompt
    assert "只允许用原题上下文做符号消歧" in prompt
    assert "不能补全学生没写在白板上的步骤、答案或推理" in prompt
    assert "禁止把它输出成学生白板内容" in prompt
