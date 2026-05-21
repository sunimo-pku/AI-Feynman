from __future__ import annotations

import gzip
import json

from app.services.volc_asr_stream import (
    VolcStreamingAsrClient,
    _parse_server_frame,
)


def test_streaming_asr_returns_none_when_unconfigured(monkeypatch) -> None:
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_API_KEY", "")
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_RESOURCE_ID", "")
    client = VolcStreamingAsrClient()
    result = client.accept_chunk(
        seq=1,
        base64_data="AAAA",
        recognize_fallback=lambda _audio, _fmt: {"text": "fallback"},
    )
    assert result is None


def test_empty_final_chunk_without_stream_does_not_connect() -> None:
    def fail_connect(*_args, **_kwargs):
        raise AssertionError("empty final chunk should not open websocket")

    client = VolcStreamingAsrClient(
        api_key="volc-key",
        resource_id="volc.seedasr.sauc.duration",
        url="wss://example.test/asr",
        connector=fail_connect,
    )
    result = client.accept_chunk(
        seq=-1,
        base64_data="",
        recognize_fallback=lambda _audio, _fmt: {"text": "fallback"},
        force=True,
    )
    assert result is None


def test_streaming_asr_uses_new_console_headers() -> None:
    captured: dict[str, object] = {}

    class FakeWs:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def send(self, payload: bytes) -> None:
            captured.setdefault("sent", []).append(payload)

        def recv(self, timeout: float | None = None) -> bytes:
            body = gzip.compress(json.dumps({
                "result": {
                    "text": "我先把根号十二化成二根号三",
                    "utterances": [{"text": "我先把根号十二化成二根号三", "definite": True}],
                }
            }, ensure_ascii=False).encode("utf-8"))
            return bytes([0x11, 0x93, 0x11, 0x00]) + (1).to_bytes(4, "big") + len(body).to_bytes(4, "big") + body

    def fake_connect(url: str, **kwargs):
        captured["url"] = url
        captured["headers"] = kwargs["additional_headers"]
        return FakeWs()

    client = VolcStreamingAsrClient(
        api_key="volc-key",
        resource_id="volc.seedasr.sauc.duration",
        url="wss://example.test/asr",
        timeout_seconds=0.2,
        connector=fake_connect,
    )
    result = client.recognize_window(
        audio_base64="AAAA",
        audio_format="pcm",
        recognize_fallback=lambda _audio, _fmt: {"text": "fallback"},
    )

    assert result is not None
    assert result.text == "我先把根号十二化成二根号三"
    assert result.is_final is True
    assert captured["url"] == "wss://example.test/asr"
    assert captured["headers"]["X-Api-Key"] == "volc-key"
    assert captured["headers"]["X-Api-Resource-Id"] == "volc.seedasr.sauc.duration"
    assert len(captured["sent"]) == 2


def test_parse_server_error_frame_raises() -> None:
    message = b'{"message":"bad audio"}'
    frame = (
        bytes([0x11, 0xF0, 0x10, 0x00])
        + (45000151).to_bytes(4, "big")
        + len(message).to_bytes(4, "big")
        + message
    )
    try:
        _parse_server_frame(frame)
    except RuntimeError as exc:
        assert "45000151" in str(exc)
    else:
        raise AssertionError("expected RuntimeError")


def test_parse_empty_json_payload_returns_empty_result() -> None:
    frame = bytes([0x11, 0x90, 0x10, 0x00]) + (0).to_bytes(4, "big")
    parsed = _parse_server_frame(frame)
    assert parsed.text == ""
    assert parsed.is_final is False
