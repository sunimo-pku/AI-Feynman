"""LiveAsrBuffer 单元测试（第九轮）。

不联网，注入式替换 recognize_fn。
"""

from __future__ import annotations

import base64

from app.services.live_asr_buffer import LiveAsrBuffer
from app.services.volc_asr_stream import StreamAsrResult, VolcStreamingAsrClient


def _b64_pcm(seconds: float, sample_rate: int = 16000) -> str:
    n_bytes = int(seconds * sample_rate * 2)
    return base64.b64encode(b"\x00\x01" * (n_bytes // 2)).decode("ascii")


def _buffer() -> LiveAsrBuffer:
    return LiveAsrBuffer(
        stream_client=VolcStreamingAsrClient(api_key="", resource_id="")
    )


def _stream_buffer(result: StreamAsrResult) -> LiveAsrBuffer:
    client = VolcStreamingAsrClient(api_key="k", resource_id="r", url="ws://asr")
    client.recognize_window = lambda **_kwargs: result  # type: ignore[method-assign]
    return LiveAsrBuffer(stream_client=client)


def test_should_flush_below_window() -> None:
    buf = _buffer()
    buf.push(seq=0, base64_data=_b64_pcm(0.5))
    assert not buf.should_flush()


def test_should_flush_at_window() -> None:
    buf = _buffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.5))
    assert buf.should_flush()


def test_drain_and_recognize_success() -> None:
    buf = _stream_buffer(StreamAsrResult(
        text="我先讲这一题",
        is_final=True,
        mode="stream",
    ))
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def fake(audio_b64: str, fmt: str) -> dict:
        raise AssertionError("window ASR must not be used")

    out = buf.flush_to_text(fake)
    assert out is not None
    assert out["text"] == "我先讲这一题"
    assert out["error"] is None
    assert not buf.has_pending


def test_drain_stream_error_is_reported() -> None:
    buf = _stream_buffer(StreamAsrResult(
        text="",
        is_final=True,
        mode="stream",
        error="stream broke",
    ))
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def fake(audio_b64: str, fmt: str) -> dict:
        raise AssertionError("window ASR must not be used")

    out = buf.flush_to_text(fake)
    assert out is not None
    assert out["text"] == ""
    assert out["error"] == "stream broke"
    # 缓冲已 drain，下一次 push 重新开始累积
    assert not buf.has_pending


def test_drain_without_stream_config_reports_error() -> None:
    buf = _buffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def fake(audio_b64: str, fmt: str) -> dict:
        raise AssertionError("window ASR must not be used")

    out = buf.flush_to_text(fake)
    assert out is not None
    assert out["text"] == ""
    assert out["error"] == "streaming_asr_not_configured"


def test_force_flush_with_partial_window() -> None:
    buf = _buffer()
    buf.push(seq=0, base64_data=_b64_pcm(0.8))
    assert not buf.should_flush()
    assert buf.should_flush(force=True)


def test_seq_regression_or_duplicate_is_dropped() -> None:
    buf = _buffer()
    buf.push(seq=10, base64_data=_b64_pcm(1.0))
    buf.push(seq=10, base64_data=_b64_pcm(1.0))  # 重复，被丢弃
    buf.push(seq=5, base64_data=_b64_pcm(1.0))  # 倒退，被丢弃
    assert buf.pending_seconds < 1.5  # 后两条没进来


def test_oversize_chunk_is_dropped() -> None:
    buf = _buffer()
    big = "a" * (3 * 1024 * 1024)
    buf.push(seq=0, base64_data=big)
    assert not buf.has_pending


def test_stream_recognize_exception_is_caught() -> None:
    client = VolcStreamingAsrClient(api_key="k", resource_id="r", url="ws://asr")

    def boom(**_kwargs) -> StreamAsrResult:
        raise RuntimeError("network broke")

    client.recognize_window = boom  # type: ignore[method-assign]
    buf = LiveAsrBuffer(stream_client=client)
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def boom(audio_b64: str, fmt: str) -> dict:
        raise AssertionError("window ASR must not be used")

    out = buf.flush_to_text(boom)
    assert out is not None
    assert out["text"] == ""
    assert "asr_exception" in (out["error"] or "")


def test_reset_clears_pending() -> None:
    buf = _buffer()
    buf.push(seq=0, base64_data=_b64_pcm(1.0))
    assert buf.has_pending
    buf.reset()
    assert not buf.has_pending
    assert buf.pending_seconds == 0.0
