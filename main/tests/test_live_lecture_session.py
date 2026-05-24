"""LiveLectureSession 单元测试（第九轮 + P3 peer assessment）。"""

from __future__ import annotations

import asyncio
import base64
from types import SimpleNamespace
from typing import Any

import pytest

from app.db import LearningProgress, LectureSessionRecord
from app.routers.lecture_live import _persist_live_session_if_needed
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


def _assessment_dict_from_bulk(role: str, bulk: dict[str, Any]) -> dict[str, Any]:
    for item in bulk.get("assessments") or []:
        if item.get("role") == role:
            return item
    raise KeyError(role)


@pytest.fixture(autouse=True)
def _mock_tts_stream_for_live_tests(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.volc_tts.synthesize_stream",
        lambda _text, _speaker: iter([]),
    )


@pytest.fixture(autouse=True)
def _patch_live_assess_one_peer(monkeypatch) -> None:
    def _fake(*, role: str, **kwargs: Any) -> dict[str, Any]:
        return _assessment_dict_from_bulk(
            role,
            _fake_peer_assessment_not_all_understood(),
        )

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        _fake,
    )


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
        "approved": True,
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

    def recognize_window(**kwargs: Any) -> StreamAsrResult:
        return StreamAsrResult(text="我先讲这一题", is_final=False, mode="stream")

    session.asr_buffer.stream_client.recognize_window = recognize_window  # type: ignore[method-assign]
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
async def test_audio_chunk_buffers_without_streaming_asr_error() -> None:
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

    assert sent == []
    assert session.asr_buffer.has_pending


@pytest.mark.asyncio
async def test_stale_client_events_do_not_pollute_current_session() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-current",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    sent.clear()

    await session.handle_event(
        {"type": "audio_chunk", "sessionId": "sess-old",
         "seq": 0, "base64": _b64_pcm(0.2)},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "ink_snapshot", "sessionId": "sess-old",
         "steps": [{"stepId": "step_1", "strokeCount": 8}],
         "boardLatex": r"x=1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "pause_detected", "sessionId": "sess-old", "silenceMs": 0},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert sent == []
    assert not session.asr_buffer.has_pending
    assert session.latest_steps == []
    assert session.board_latex == ""
    assert session.round_index == 0


@pytest.mark.asyncio
async def test_same_question_session_start_resets_current_round_board_only() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-1",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "ink_snapshot", "sessionId": "sess-1",
         "steps": [{"stepId": "step_1", "strokeCount": 4}],
         "boardLatex": r"x=1", "boardImageBase64": "img"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    session.history.append({"role": "student", "displayName": "我", "text": "上一轮"})
    session.round_index = 1

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-2",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert session.round_index == 1
    assert session.history
    assert session.latest_steps == []
    assert session.board_latex == ""
    assert session.board_plain_text == ""
    assert session.pending_board_image_b64 == ""


@pytest.mark.asyncio
async def test_empty_ink_snapshot_clears_current_board_state() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-board",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "ink_snapshot", "sessionId": "sess-board",
         "steps": [{"stepId": "step_1", "strokeCount": 4}],
         "boardLatex": r"x=1", "boardPlainText": "x 等于 1",
         "boardImageBase64": "img"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    assert session.latest_steps
    assert session.board_latex
    assert session.pending_board_image_b64 == "img"

    await session.handle_event(
        {"type": "ink_snapshot", "sessionId": "sess-board", "steps": []},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert session.latest_steps == []
    assert session.board_latex == ""
    assert session.board_plain_text == ""
    assert session.pending_board_image_b64 == ""


@pytest.mark.asyncio
async def test_new_connection_session_start_restores_live_context() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {
            "type": "session_start",
            "sessionId": "sess-restored",
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q1",
            "completedRoundIndex": 2,
            "history": [
                {
                    "role": "student",
                    "displayName": "我",
                    "text": "上一轮回答",
                    "highlightStepIds": ["board"],
                }
            ],
            "roundBoardSnapshots": [
                {
                    "roundIndex": 1,
                    "boardLatex": r"x=1",
                    "boardPlainText": "x 等于 1",
                    "strokeCount": 5,
                    "boardImageBase64": "ignored-in-prompt",
                }
            ],
        },
        send=send,
        recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert session.round_index == 2
    assert session.history[-1]["text"] == "上一轮回答"
    assert len(session.round_board_snapshots) == 1
    assert session.round_board_snapshots[0].board_latex == r"x=1"
    assert session.latest_steps == []


@pytest.mark.asyncio
async def test_pause_without_current_round_input_ignores_old_transcript() -> None:
    called = False

    def fail_if_peer_called(**_kwargs: Any) -> dict[str, Any]:
        nonlocal called
        called = True
        raise AssertionError("peer assessment should not run without current input")

    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-current-input",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=fail_if_peer_called,
    )
    session.transcript_segments.append("上一轮语音")
    session._mark_transcript_round_consumed()
    sent.clear()

    await session.handle_event(
        {"type": "pause_detected", "sessionId": "sess-current-input", "silenceMs": 0},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=fail_if_peer_called,
    )

    assert called is False
    assert any(
        s["type"] == EVT_WARNING and s.get("message") == "no_steps_yet"
        for s in sent
    )
    assert session.round_index == 0


@pytest.mark.asyncio
async def test_pause_stops_pipeline_when_asr_flush_fails(monkeypatch) -> None:
    called = False

    def fail_if_peer_called(*, role: str, **kwargs: Any) -> dict[str, Any]:
        nonlocal called
        called = True
        raise AssertionError("peer assessment should not run after ASR failure")

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        fail_if_peer_called,
    )
    session = LiveLectureSession()
    session.asr_buffer.stream_client.enabled = True
    session.asr_buffer.stream_client.recognize_window = (  # type: ignore[method-assign]
        lambda **_kwargs: StreamAsrResult(
            text="",
            is_final=True,
            mode="stream",
            error="volc unavailable",
        )
    )
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-asr-fail",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "ink_snapshot",
         "steps": [{"stepId": "step_1", "strokeCount": 1}]},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await session.handle_event(
        {"type": "audio_chunk", "seq": 0, "base64": _b64_pcm(2.6)},
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
    assert EVT_ERROR in types
    assert EVT_LISTENING in types
    assert EVT_THINKING not in types
    assert EVT_PEER_ASSESSMENTS not in types
    assert EVT_ROUND_DONE not in types
    assert session.round_index == 0
    assert called is False


@pytest.mark.asyncio
async def test_pause_without_steps_emits_warning() -> None:
    session = LiveLectureSession()
    session.asr_buffer.stream_client.enabled = True
    session.asr_buffer.stream_client.recognize_window = (  # type: ignore[method-assign]
        lambda **_kwargs: StreamAsrResult(
            text="我先讲这一题",
            is_final=True,
            mode="stream",
        )
    )
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
async def test_all_understood_emits_completed_round_done_and_summary(
    monkeypatch,
) -> None:
    def _fake_all(*, role: str, **kwargs: Any) -> dict[str, Any]:
        return _assessment_dict_from_bulk(
            role,
            _fake_peer_assessment_all_understood(),
        )

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        _fake_all,
    )
    session = LiveLectureSession()
    session.asr_buffer.stream_client.enabled = True
    session.asr_buffer.stream_client.recognize_window = (  # type: ignore[method-assign]
        lambda **_kwargs: StreamAsrResult(
            text="我把前提条件讲清楚了",
            is_final=True,
            mode="stream",
        )
    )
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


@pytest.mark.asyncio
async def test_multi_round_same_question_passes_incremental_round_and_history(
    monkeypatch,
) -> None:
    calls: list[dict[str, Any]] = []

    def fake_assess_one(*, role: str, **kwargs: Any) -> dict[str, Any]:
        calls.append({"role": role, **kwargs})
        return _assessment_dict_from_bulk(
            role,
            _fake_peer_assessment_not_all_understood(),
        )

    monkeypatch.setattr(
        "app.services.peer_assessment_agent.assess_one_peer",
        fake_assess_one,
    )
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    async def run_round(step_id: str) -> None:
        await session.handle_event(
            {"type": "ink_snapshot",
             "steps": [{"stepId": step_id, "strokeCount": 2,
                        "latex": "", "plainText": ""}]},
            send=send, recognize_fn=_fake_recognize,
            peer_assessment_fn=_fake_peer_assessment_not_all_understood,
        )
        await session.handle_event(
            {"type": "pause_detected", "silenceMs": 1600},
            send=send, recognize_fn=_fake_recognize,
            peer_assessment_fn=_fake_peer_assessment_not_all_understood,
        )

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-same-rounds",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1",
         "questionPrompt": "化简：\\sqrt{12}"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    await run_round("step_1")
    await run_round("step_2")

    assert session.round_index == 2
    assert len(calls) == 6
    first_round = calls[:3]
    second_round = calls[3:]
    assert {c["round_index"] for c in first_round} == {1}
    assert {c["round_index"] for c in second_round} == {2}
    assert all(c["history"] == [] for c in first_round)
    assert all(
        any(item.get("role") == "student" for item in c["history"])
        for c in second_round
    )


@pytest.mark.asyncio
async def test_session_start_same_question_resets_asr_buffer_for_seq_zero() -> None:
    """同题再次 session_start 时客户端 seq 归零，服务端必须 reset 缓冲。"""
    session = LiveLectureSession(
        session_id="sess-seq",
        section_id="pep-g7-up-s1-1",
        question_id="q1",
        question_prompt="prompt",
    )
    session._started = True
    session.asr_buffer.push(seq=0, base64_data=_b64_pcm(0.5))
    session.asr_buffer.push(seq=12, base64_data=_b64_pcm(0.5))
    assert session.asr_buffer.has_pending

    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {
            "type": "session_start",
            "sessionId": "sess-seq-2",
            "sectionId": "pep-g7-up-s1-1",
            "questionId": "q1",
            "questionPrompt": "prompt",
        },
        send=send,
        recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert not session.asr_buffer.has_pending
    session.asr_buffer.push(seq=0, base64_data=_b64_pcm(0.4))
    assert session.asr_buffer.has_pending
    assert session.asr_buffer.pending_seconds > 0.3


@pytest.mark.asyncio
async def test_session_start_preserves_same_question_history_and_clears_tts() -> None:
    session = LiveLectureSession(
        session_id="sess-same",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="old prompt",
        round_index=2,
        last_status="completed",
        last_mastery_delta=1,
    )
    session._started = True
    session.history.append({"role": "student", "text": "first round"})
    session.transcript_segments.append("第一轮讲解")
    session._transcript_round_start = 1
    session._tts_buffer_by_turn["t1"] = "旧题尾句"
    session._tts_seq_by_turn["t1"] = 2
    session._tts_role_by_turn["t1"] = "teacher"
    pending_tts = asyncio.create_task(asyncio.sleep(60))
    session._tts_tail_by_turn["t1"] = pending_tts
    sent: list[dict[str, Any]] = []

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {"type": "session_start", "sessionId": "sess-same",
         "sectionId": "pep-g8-down-s16-3", "questionId": "q1",
         "questionPrompt": "new prompt"},
        send=send, recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    await asyncio.sleep(0)

    assert session.round_index == 2
    assert session.history == [{"role": "student", "text": "first round"}]
    assert session.transcript_segments == ["第一轮讲解"]
    assert session.last_status == "needs_explanation"
    assert session.last_mastery_delta == 0
    assert session._tts_buffer_by_turn == {}
    assert session._tts_seq_by_turn == {}
    assert session._tts_role_by_turn == {}
    assert session._tts_tail_by_turn == {}
    assert pending_tts.cancelled()
    assert any(s["type"] == EVT_LISTENING for s in sent)


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


class _FakeQuery:
    def __init__(self, result: Any = None) -> None:
        self._result = result

    def filter(self, *args: Any, **kwargs: Any) -> "_FakeQuery":
        return self

    def first(self) -> Any:
        return self._result


class _FakeDb:
    def __init__(
        self,
        existing_progress: Any = None,
        existing_session: Any = None,
    ) -> None:
        self.existing_progress = existing_progress
        self.existing_session = existing_session
        self.added: list[Any] = []
        self.committed = False
        self.closed = False

    def add(self, row: Any) -> None:
        self.added.append(row)

    def query(self, model: Any) -> _FakeQuery:
        if model is LectureSessionRecord:
            return _FakeQuery(self.existing_session)
        if model is LearningProgress:
            return _FakeQuery(self.existing_progress)
        return _FakeQuery()

    def commit(self) -> None:
        self.committed = True

    def rollback(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


def test_persist_live_session_does_not_update_progress_when_not_completed(
    monkeypatch,
) -> None:
    fake_db = _FakeDb()
    monkeypatch.setattr("app.routers.lecture_live.SessionLocal", lambda: fake_db)
    monkeypatch.setattr(
        "app.routers.lecture_live.ensure_student_profile",
        lambda _db, _user: SimpleNamespace(id=42),
    )
    session = LiveLectureSession(
        session_id="sess-progress-0",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="题目",
        round_index=1,
        last_status="needs_explanation",
        last_mastery_delta=0,
    )

    _persist_live_session_if_needed(SimpleNamespace(username="student"), session)

    assert fake_db.committed is True
    assert fake_db.closed is True
    assert any(isinstance(row, LectureSessionRecord) for row in fake_db.added)
    assert not any(isinstance(row, LearningProgress) for row in fake_db.added)


def test_persist_live_session_updates_progress_only_for_completed_positive_delta(
    monkeypatch,
) -> None:
    fake_db = _FakeDb()
    marked: list[dict[str, Any]] = []
    monkeypatch.setattr("app.routers.lecture_live.SessionLocal", lambda: fake_db)
    monkeypatch.setattr(
        "app.routers.lecture_live.ensure_student_profile",
        lambda _db, _user: SimpleNamespace(id=42),
    )
    monkeypatch.setattr(
        "app.services.assignment_service.mark_assignments_completed",
        lambda *args, **kwargs: marked.append(kwargs),
    )
    session = LiveLectureSession(
        session_id="sess-progress-1",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="题目",
        round_index=2,
        last_status="completed",
        last_mastery_delta=1,
    )
    session.transcript_segments.append("我讲清楚了")

    _persist_live_session_if_needed(SimpleNamespace(username="student"), session)

    progress_rows = [
        row for row in fake_db.added if isinstance(row, LearningProgress)
    ]
    assert len(progress_rows) == 1
    assert progress_rows[0].completed_rounds == 1
    assert progress_rows[0].mastery_score == 10
    assert marked == [{
        "student_id": 42,
        "section_id": "pep-g8-down-s16-3",
        "question_id": "q1",
        "summary": "我讲清楚了",
        "mastery_delta": 1,
        "round_count": 2,
    }]


def test_persist_live_session_is_idempotent_for_existing_completed_session(
    monkeypatch,
) -> None:
    existing_session = LectureSessionRecord(
        student_id=42,
        session_id="sess-progress-1",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        status="completed",
        mastery_delta=1,
        round_count=2,
        mastery_after=10,
    )
    existing_progress = LearningProgress(
        student_id=42,
        section_id="pep-g8-down-s16-3",
        completed_rounds=1,
        mastery_score=10,
    )
    fake_db = _FakeDb(
        existing_progress=existing_progress,
        existing_session=existing_session,
    )
    marked: list[dict[str, Any]] = []
    monkeypatch.setattr("app.routers.lecture_live.SessionLocal", lambda: fake_db)
    monkeypatch.setattr(
        "app.routers.lecture_live.ensure_student_profile",
        lambda _db, _user: SimpleNamespace(id=42),
    )
    monkeypatch.setattr(
        "app.services.assignment_service.mark_assignments_completed",
        lambda *args, **kwargs: marked.append(kwargs),
    )
    session = LiveLectureSession(
        session_id="sess-progress-1",
        section_id="pep-g8-down-s16-3",
        question_id="q1",
        question_prompt="题目",
        round_index=2,
        last_status="completed",
        last_mastery_delta=1,
    )
    session.transcript_segments.append("重复断线保存")

    _persist_live_session_if_needed(SimpleNamespace(username="student"), session)

    assert fake_db.committed is True
    assert fake_db.added == []
    assert existing_progress.completed_rounds == 1
    assert existing_progress.mastery_score == 10
    assert marked == []


@pytest.mark.asyncio
async def test_pause_archives_round_board_snapshot() -> None:
    session = LiveLectureSession()
    sent: list[dict[str, Any]] = []
    captured_kwargs: list[dict[str, Any]] = []

    def capture_peer(*, role: str, **kwargs: Any) -> dict[str, Any]:
        captured_kwargs.append(dict(kwargs))
        return _assessment_dict_from_bulk(
            role,
            _fake_peer_assessment_not_all_understood(),
        )

    async def send(payload: dict[str, Any]) -> None:
        sent.append(payload)

    await session.handle_event(
        {
            "type": "session_start",
            "sessionId": "sess-board",
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q1",
            "questionPrompt": "化简",
        },
        send=send,
        recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    sent.clear()

    await session.handle_event(
        {
            "type": "ink_snapshot",
            "steps": [
                {
                    "stepId": "step_1",
                    "strokeCount": 2,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                    "latex": "",
                    "plainText": "",
                }
            ],
            "boardLatex": r"\sqrt{12}",
            "boardPlainText": "分解 twelve",
            "boardImageBase64": "aGVsbG8=",
        },
        send=send,
        recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )
    import app.services.peer_assessment_agent as peer_mod

    peer_mod.assess_one_peer = capture_peer  # type: ignore[method-assign]

    await session.handle_event(
        {"type": "pause_detected", "silenceMs": 800},
        send=send,
        recognize_fn=_fake_recognize,
        peer_assessment_fn=_fake_peer_assessment_not_all_understood,
    )

    assert len(session.round_board_snapshots) == 1
    snap = session.round_board_snapshots[0]
    assert snap.round_index == 1
    assert snap.board_latex == r"\sqrt{12}"
    assert snap.board_plain_text == "分解 twelve"
    assert snap.board_image_base64 == "aGVsbG8="
    assert session.round_index == 1
    assert captured_kwargs
    assert captured_kwargs[0].get("round_board_snapshots") == []

