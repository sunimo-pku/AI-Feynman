"""LiveLectureSession 单元测试（第九轮 + P3 peer assessment）。"""

from __future__ import annotations

import asyncio
import base64
from typing import Any

import pytest

from app.services.live_lecture_session import (
    EVT_LISTENING,
    EVT_PEER_ASSESSMENTS,
    EVT_ERROR,
    EVT_ROUND_DONE,
    EVT_THINKING,
    EVT_WARNING,
    LiveLectureSession,
    _split_text_into_deltas,
)
from app.services.volc_asr_stream import StreamAsrResult


def _b64_pcm(seconds: float, sample_rate: int = 16000) -> str:
    n_bytes = int(seconds * sample_rate * 2)
    return base64.b64encode(b"\x00\x01" * (n_bytes // 2)).decode("ascii")


@pytest.fixture(autouse=True)
def _disable_stream_asr_for_session_tests(monkeypatch) -> None:
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_API_KEY", "")
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_RESOURCE_ID", "")


def _fake_recognize(audio_b64: str, fmt: str) -> dict:
    return {"text": "我先把根号十二化成二根号三"}


def _fake_peer_assessment_not_all_understood(**kwargs: Any) -> dict[str, Any]:
    return {
        "status": "needs_explanation",
        "mastery_delta": 0,
        "all_understood": False,
        "assessments": [
            {
                "role": "xiaoming",
                "display_name": "小明",
                "understood": False,
                "reason": "你为什么把 12 拆成 4×3？",
                "highlight_step_ids": ["step_1"],
            },
            {
                "role": "daxiong",
                "display_name": "大雄",
                "understood": True,
                "reason": "化简步骤我听懂了。",
                "highlight_step_ids": ["step_1"],
            },
            {
                "role": "monitor",
                "display_name": "班长",
                "understood": True,
                "reason": "方法归纳清楚了。",
                "highlight_step_ids": ["step_1"],
            },
        ],
        "source": "llm",
    }


def _fake_peer_assessment_all_understood(**kwargs: Any) -> dict[str, Any]:
    return {
        "status": "completed",
        "mastery_delta": 1,
        "all_understood": True,
        "assessments": [
            {
                "role": "xiaoming",
                "display_name": "小明",
                "understood": True,
                "reason": "前提条件讲清楚了。",
                "highlight_step_ids": ["step_2"],
            },
            {
                "role": "daxiong",
                "display_name": "大雄",
                "understood": True,
                "reason": "计算细节没问题。",
                "highlight_step_ids": ["step_2"],
            },
            {
                "role": "monitor",
                "display_name": "班长",
                "understood": True,
                "reason": "方法归纳也听懂了。",
                "highlight_step_ids": ["step_2"],
            },
        ],
        "source": "llm",
    }


def _fake_teacher_summary(**kwargs: Any) -> dict[str, Any]:
    return {
        "turn_id": "summary_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": "你说出了 a≥0 的前提，这一题讲清楚了。",
        "highlight_step_ids": ["step_2"],
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
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
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
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    assert keep is True
    assert any(s["type"] == EVT_WARNING for s in sent)


@pytest.mark.asyncio
async def test_audio_chunk_then_pause_yields_peer_assessments() -> None:
    session = LiveLectureSession()
    session.asr_buffer.stream_client.enabled = True

    def accept_chunk(**kwargs: Any) -> StreamAsrResult:
        if kwargs.get("force"):
            return StreamAsrResult(text="", is_final=True, mode="stream")
        return StreamAsrResult(text="我先讲这一题", is_final=False, mode="stream")

    session.asr_buffer.stream_client.accept_chunk = accept_chunk  # type: ignore[method-assign]
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-2",
         "sectionId": "pep-g8-down-s16-3",
         "questionId": "q-s16-3-001",
         "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    sent.clear()

    await session.handle_event(
        {"type": "audio_chunk", "seq": 0,
         "format": "pcm16", "sampleRate": 16000,
         "base64": _b64_pcm(2.6)},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_1", "strokeCount": 3,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    types = [s["type"] for s in sent]
    assert EVT_THINKING in types
    assert EVT_PEER_ASSESSMENTS in types
    assert EVT_ROUND_DONE in types
    assert types.count(EVT_LISTENING) >= 1

    peer_evt = next(s for s in sent if s["type"] == EVT_PEER_ASSESSMENTS)
    assert peer_evt["allUnderstood"] is False
    assert len(peer_evt["assessments"]) == 3

    round_done = next(s for s in sent if s["type"] == EVT_ROUND_DONE)
    assert round_done["status"] == "needs_explanation"


@pytest.mark.asyncio
async def test_audio_chunk_without_streaming_asr_emits_error() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-no-asr",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    sent.clear()

    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(0.2)},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert sent[-1]["type"] == EVT_ERROR
    assert sent[-1]["message"] == "streaming_asr_not_configured"


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
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    sent.clear()

    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
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
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
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
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    keep = await session.handle_event(
        {"type": "session_end"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    assert keep is False


@pytest.mark.asyncio
async def test_all_understood_emits_completed_round_done_and_summary() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-5",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_all_understood,
        teacher_summary_fn=_fake_teacher_summary,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_2", "strokeCount": 1,
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_all_understood,
        teacher_summary_fn=_fake_teacher_summary,
    )
    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(2.6)},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_all_understood,
        teacher_summary_fn=_fake_teacher_summary,
    )
    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 1600},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_all_understood,
        teacher_summary_fn=_fake_teacher_summary,
    )
    peer_evt = next(s for s in sent if s["type"] == EVT_PEER_ASSESSMENTS)
    assert peer_evt["allUnderstood"] is True
    assert peer_evt["teacherSummary"] is not None

    round_done = next(s for s in sent if s["type"] == EVT_ROUND_DONE)
    assert round_done["status"] == "completed"
    assert round_done["masteryDelta"] == 1
    assert round_done["allUnderstood"] is True
    assert session.last_status == "completed"


def _fake_teacher_hint(**kwargs: Any) -> dict[str, Any]:
    return {
        "turn_id": "hint_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": "先检查被开方数是否非负。",
        "highlight_step_ids": ["step_1"],
    }


@pytest.mark.asyncio
async def test_request_hint_emits_teacher_turn() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-hint",
         "sectionId": "pep-g8-down-s16-1", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
        teacher_hint_fn=_fake_teacher_hint,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_1", "strokeCount": 1,
                    "latex": "", "plainText": ""}]},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
        teacher_hint_fn=_fake_teacher_hint,
    )
    await session.handle_event(
        {"type": "request_hint"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
        teacher_hint_fn=_fake_teacher_hint,
    )

    from app.services.live_lecture_session import EVT_AGENT_TURN_START

    starts = [s for s in sent if s["type"] == EVT_AGENT_TURN_START]
    assert len(starts) == 1
    assert starts[0]["role"] == "teacher"
    assert any(s["type"] == EVT_LISTENING for s in sent)


def test_split_text_into_deltas_basic() -> None:
    out = _split_text_into_deltas("abcdefghij", chunk_chars=3)
    assert out == ["abc", "def", "ghi", "j"]


def test_split_text_empty_or_zero() -> None:
    assert _split_text_into_deltas("", chunk_chars=3) == []
    assert _split_text_into_deltas("abc", chunk_chars=0) == ["abc"]
