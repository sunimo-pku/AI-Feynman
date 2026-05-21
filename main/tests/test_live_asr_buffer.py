"""LiveAsrBuffer 单元测试（第九轮）。

不联网，注入式替换 recognize_fn。
"""

from __future__ import annotations

import base64

from app.services.live_asr_buffer import LiveAsrBuffer


def _b64_pcm(seconds: float, sample_rate: int = 16000) -> str:
    n_bytes = int(seconds * sample_rate * 2)
    return base64.b64encode(b"\x00\x01" * (n_bytes // 2)).decode("ascii")


def test_should_flush_below_window() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(0.5))
    assert not buf.should_flush()


def test_should_flush_at_window() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.5))
    assert buf.should_flush()


def test_drain_and_recognize_success() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def fake(audio_b64: str, fmt: str) -> dict:
        assert fmt == "pcm"
        assert audio_b64
        return {"text": "我先把根号十二化成二根号三"}

    out = buf.flush_to_text(fake)
    assert out is not None
    assert out["text"] == "我先把根号十二化成二根号三"
    assert out["error"] is None
    assert not buf.has_pending


def test_drain_recognize_error_does_not_terminate() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def fake(audio_b64: str, fmt: str) -> dict:
        return {"error": "未检测到有效语音"}

    out = buf.flush_to_text(fake)
    assert out is not None
    assert out["text"] == ""
    assert out["error"] == "未检测到有效语音"
    # 缓冲已 drain，下一次 push 重新开始累积
    assert not buf.has_pending


def test_force_flush_with_partial_window() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(0.8))
    assert not buf.should_flush()
    assert buf.should_flush(force=True)


def test_seq_regression_is_dropped() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=10, base64_data=_b64_pcm(1.0))
    buf.push(seq=5, base64_data=_b64_pcm(1.0))  # 倒退，被丢弃
    assert buf.pending_seconds < 1.5  # 第二条没进来


def test_oversize_chunk_is_dropped() -> None:
    buf = LiveAsrBuffer()
    big = "a" * (3 * 1024 * 1024)
    buf.push(seq=0, base64_data=big)
    assert not buf.has_pending


def test_recognize_exception_is_caught() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(2.6))

    def boom(audio_b64: str, fmt: str) -> dict:
        raise RuntimeError("network broke")

    out = buf.flush_to_text(boom)
    assert out is not None
    assert out["text"] == ""
    assert "asr_exception" in (out["error"] or "")


def test_reset_clears_pending() -> None:
    buf = LiveAsrBuffer()
    buf.push(seq=0, base64_data=_b64_pcm(1.0))
    assert buf.has_pending
    buf.reset()
    assert not buf.has_pending
    assert buf.pending_seconds == 0.0
