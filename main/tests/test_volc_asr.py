from __future__ import annotations

import base64
import struct

from app.services.volc_asr import pcm16le_mono_to_wav, prepare_audio_for_volc


def test_pcm16le_mono_to_wav_has_riff_header() -> None:
    pcm = struct.pack("<hh", 100, -100)
    wav = pcm16le_mono_to_wav(pcm)
    assert wav[:4] == b"RIFF"
    assert wav[8:12] == b"WAVE"


def test_prepare_audio_for_volc_wraps_pcm() -> None:
    pcm = b"\x01\x00" * 8000
    b64 = base64.b64encode(pcm).decode("ascii")
    out_b64, fmt, pcm_len = prepare_audio_for_volc(b64, "pcm")
    assert fmt == "wav"
    assert pcm_len == len(pcm)
    wav = base64.b64decode(out_b64)
    assert wav[:4] == b"RIFF"
