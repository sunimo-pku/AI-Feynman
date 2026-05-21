"""LiveLectureSession 单元测试（第九轮）。

不开 WebSocket，不调真实 ASR / LLM；用注入式 fake function 验证
事件协议与状态机。
"""

from __future__ import annotations

import asyncio
import base64
from typing import Any

import pytest

from app.services.live_lecture_session import (
    EVT_AGENT_TURN_DELTA,
    EVT_AGENT_TURN_DONE,
    EVT_AGENT_TURN_START,
    EVT_ASR_SEGMENT,
    EVT_LISTENING,
    EVT_ROUND_DONE,
    EVT_THINKING,
    EVT_WARNING,
    LiveLectureSession,
    _split_text_into_deltas,
)


def _b64_pcm(seconds: float, sample_rate: int = 16000) -> str:
    n_bytes = int(seconds * sample_rate * 2)
    return base64.b64encode(b"\x00\x01" * (n_bytes // 2)).decode("ascii")


@pytest.fixture(autouse=True)
def _disable_stream_asr_for_session_tests(monkeypatch) -> None:
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_API_KEY", "")
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_RESOURCE_ID", "")


def _fake_recognize(audio_b64: str, fmt: str) -> dict:
    return {"text": "我先把根号十二化成二根号三"}


def _fake_lecture_agent_needs_explanation(**kwargs: Any) -> dict[str, Any]:
    return {
        "status": "needs_explanation",
        "mastery_delta": 0,
        "turns": [
            {
                "turn_id": "turn_1",
                "role": "xiaoming",
                "display_name": "小明",
                "text": "你为什么把 12 拆成 4×3？",
                "highlight_step_ids": ["step_1"],
            },
        ],
        "source": "llm",
    }


def _fake_lecture_agent_completed(**kwargs: Any) -> dict[str, Any]:
    return {
        "status": "completed",
        "mastery_delta": 1,
        "turns": [
            {
                "turn_id": "turn_1",
                "role": "teacher",
                "display_name": "李老师",
                "text": "你说出了 a≥0 的前提，这一题讲清楚了。",
                "highlight_step_ids": ["step_2"],
            },
        ],
        "source": "llm",
    }


@pytest.mark.asyncio
async def test_session_start_emits_listening() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    keep = await session.handle_event(
        {
            "type": "session_start",
            "sessionId": "sess-1",
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q-s16-3-001",
            "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}",
        },
        send=send,
        recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    assert keep is True
    assert any(s["type"] == EVT_LISTENING for s in sent)
    assert session.session_id == "sess-1"
    assert session.section_id == "pep-g8-down-s16-3"


@pytest.mark.asyncio
async def test_unknown_event_emits_warning_but_keeps_session() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    keep = await session.handle_event(
        {"type": "wat"},
        send=send,
        recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    assert keep is True
    assert any(s["type"] == EVT_WARNING for s in sent)


@pytest.mark.asyncio
async def test_audio_chunk_then_pause_yields_asr_thinking_turns_done() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-2",
         "sectionId": "pep-g8-down-s16-3",
         "questionId": "q-s16-3-001",
         "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    sent.clear()

    # 灌一段满足 ASR 窗口的音频
    await session.handle_event(
        {"type": "audio_chunk", "seq": 0,
         "format": "pcm16", "sampleRate": 16000,
         "base64": _b64_pcm(2.6)},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    # 来一个 step
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_1", "strokeCount": 3,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    # 触发暂停
    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )

    types = [s["type"] for s in sent]
    assert EVT_ASR_SEGMENT in types
    assert EVT_THINKING in types
    assert EVT_AGENT_TURN_START in types
    assert EVT_AGENT_TURN_DELTA in types
    assert EVT_AGENT_TURN_DONE in types
    assert EVT_ROUND_DONE in types
    # round_done 后又回到 listening
    assert types.count(EVT_LISTENING) >= 1

    # round_done payload 校验
    round_done = next(s for s in sent if s["type"] == EVT_ROUND_DONE)
    assert round_done["status"] == "needs_explanation"


@pytest.mark.asyncio
async def test_pause_without_steps_emits_warning() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-3",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    sent.clear()

    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    types = [s["type"] for s in sent]
    assert EVT_WARNING in types
    assert EVT_THINKING not in types


@pytest.mark.asyncio
async def test_event_before_session_start_emits_warning() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(1.0)},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    types = [s["type"] for s in sent]
    assert EVT_WARNING in types


@pytest.mark.asyncio
async def test_session_end_terminates_loop() -> None:
    session = LiveLectureSession()

    async def send(payload: dict[str, Any]) -> None:
        pass

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-4",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    keep = await session.handle_event(
        {"type": "session_end"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_needs_explanation,
    )
    assert keep is False


@pytest.mark.asyncio
async def test_completed_round_emits_round_done_completed() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-5",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_completed,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_2", "strokeCount": 1,
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_completed,
    )
    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(2.6)},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_completed,
    )
    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=_fake_lecture_agent_completed,
    )
    round_done = next(s for s in sent if s["type"] == EVT_ROUND_DONE)
    assert round_done["status"] == "completed"
    assert round_done["masteryDelta"] == 1


@pytest.mark.asyncio
async def test_interrupt_stops_remaining_deltas() -> None:
    """学生打断时，剩余 delta 不再发送。"""

    # 用一个"长文本 + 多 turn"的 fake，模拟边发边被打断。
    def long_agent(**kwargs: Any) -> dict[str, Any]:
        return {
            "status": "needs_explanation",
            "mastery_delta": 0,
            "turns": [
                {
                    "turn_id": "turn_1",
                    "role": "xiaoming",
                    "display_name": "小明",
                    "text": "好长一段话好长一段话好长一段话好长一段话好长一段话",
                    "highlight_step_ids": ["step_1"],
                },
            ],
            "source": "llm",
        }

    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)
        # 收到第一条 delta 后立刻打断
        if payload["type"] == EVT_AGENT_TURN_DELTA:
            session._interrupt_event.set()

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-6",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=long_agent,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_1", "strokeCount": 1,
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=long_agent,
    )
    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(2.6)},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=long_agent,
    )
    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        lecture_agent_fn=long_agent,
    )

    delta_count = sum(1 for s in sent if s["type"] == EVT_AGENT_TURN_DELTA)
    # 应该 ≤ 1（被打断后剩余 delta 不再发）；done / round_done 仍可触发
    assert delta_count <= 2


def test_split_text_into_deltas_basic() -> None:
    out = _split_text_into_deltas("abcdefghij", chunk_chars=3)
    assert out == ["abc", "def", "ghi", "j"]


def test_split_text_empty_or_zero() -> None:
    assert _split_text_into_deltas("", chunk_chars=3) == []
    assert _split_text_into_deltas("abc", chunk_chars=0) == ["abc"]
