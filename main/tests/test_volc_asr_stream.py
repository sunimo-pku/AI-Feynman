from __future__ import annotations

from app.services.volc_asr_stream import VolcStreamingAsrClient


def test_streaming_asr_reports_fallback_when_unconfigured(monkeypatch) -> None:
    monkeypatch.setattr("app.services.volc_asr_stream.Config.VOLC_ASR_STREAM_APP_ID", "")
    client = VolcStreamingAsrClient()
    result = client.accept_chunk(
        seq=1,
        base64_data="AAAA",
        recognize_fallback=lambda _audio, _fmt: {"text": "fallback"},
    )
    assert result is None
