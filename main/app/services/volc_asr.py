import base64
import struct
import time
import uuid

import httpx

from app.config import Config

ASR_SUBMIT_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
ASR_QUERY_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
ASR_FLASH_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
ASR_RESOURCE_ID = "volc.bigasr.auc"
ASR_FLASH_RESOURCE_ID = "volc.bigasr.auc_turbo"

# 16kHz · mono · 16-bit LE（与 Flutter AudioStreamService 一致）
_DEFAULT_SAMPLE_RATE = 16000
_DEFAULT_CHANNELS = 1
_DEFAULT_BITS = 16
_BYTES_PER_SECOND = _DEFAULT_SAMPLE_RATE * _DEFAULT_CHANNELS * (_DEFAULT_BITS // 8)
# 每日挑战等短语音走极速版（一次往返）；更长音频仍走 submit+query
_FLASH_MAX_SECONDS = 120


def pcm16le_mono_to_wav(
    pcm: bytes,
    *,
    sample_rate: int = _DEFAULT_SAMPLE_RATE,
    channels: int = _DEFAULT_CHANNELS,
    bits: int = _DEFAULT_BITS,
) -> bytes:
    """把裸 PCM16 小端单声道封装成 WAV，供火山录音文件识别 API 使用。"""
    if not pcm:
        return b""
    data_size = len(pcm)
    byte_rate = sample_rate * channels * (bits // 8)
    block_align = channels * (bits // 8)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        1,
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits,
        b"data",
        data_size,
    )
    return header + pcm


def prepare_audio_for_volc(
    audio_base64: str,
    audio_format: str,
) -> tuple[str, str, int]:
    """规范化上传格式。返回 (base64, volc_format, pcm_byte_length)。"""
    fmt = (audio_format or "wav").strip().lower()
    raw = base64.b64decode(audio_base64 or "", validate=False)

    if fmt in ("pcm", "pcm16", "raw"):
        pcm = raw
        wav = pcm16le_mono_to_wav(pcm)
        return base64.b64encode(wav).decode("ascii"), "wav", len(pcm)

    if fmt == "wav" and len(raw) >= 12 and raw[:4] == b"RIFF":
        return audio_base64, "wav", max(0, len(raw) - 44)

    return audio_base64, fmt if fmt in ("wav", "mp3", "ogg") else "wav", len(raw)


def _friendly_asr_error(status_code: str, message: str, *, phase: str) -> str:
    if status_code == "20000003":
        return "未检测到有效语音，请靠近麦克风重试"
    if status_code == "45000002":
        return "录音为空，请先按住麦克风讲完解题思路"
    if status_code == "45000151":
        return "音频格式无法识别，请重新录制后再试"
    if status_code == "55000031":
        return "语音识别服务繁忙，请稍后再试"
    if status_code in ("20000001", "20000002"):
        return f"ASR {phase} still processing"
    return f"ASR {phase} failed: [{status_code}] {message}"


def _parse_success_body(data: dict) -> dict:
    result = data.get("result", {}) or {}
    text = result.get("text", "") or ""
    utterances_raw = result.get("utterances", []) or []
    audio_info = data.get("audio_info", {}) or {}
    duration_ms = audio_info.get("duration", 0)

    utterances = []
    for u in utterances_raw:
        additions = u.get("additions", {}) or {}
        utterances.append({
            "text": u.get("text", ""),
            "start_time": u.get("start_time", 0),
            "end_time": u.get("end_time", 0),
            "emotion": additions.get("emotion", ""),
            "speech_rate": additions.get("speech_rate", 0),
            "volume": additions.get("volume", 0),
        })

    return {
        "text": text,
        "utterances": utterances,
        "audio_duration": duration_ms,
    }


def _recognize_flash(audio_base64: str, audio_format: str) -> dict | None:
    """短音频极速识别；失败时返回 None 由调用方回退标准版。"""
    task_id = str(uuid.uuid4())
    headers = {
        "Content-Type": "application/json",
        "X-Api-Key": Config.VOLC_API_KEY,
        "X-Api-Resource-Id": ASR_FLASH_RESOURCE_ID,
        "X-Api-Request-Id": task_id,
        "X-Api-Sequence": "-1",
    }
    payload = {
        "user": {"uid": "aiic_user"},
        "audio": {"data": audio_base64, "format": audio_format},
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
        },
    }
    try:
        with httpx.Client(timeout=45.0) as client:
            resp = client.post(ASR_FLASH_URL, headers=headers, json=payload)
    except httpx.TimeoutException:
        return None
    except Exception:
        return None

    status_code = resp.headers.get("X-Api-Status-Code", "")
    message = resp.headers.get("X-Api-Message", "")
    if status_code == "20000000":
        try:
            return _parse_success_body(resp.json())
        except Exception:
            return None
    if status_code == "20000003":
        return {"error": _friendly_asr_error(status_code, message, phase="flash")}
    return None


def recognize(audio_base64: str, audio_format: str = "wav") -> dict:
    """调用火山引擎大模型录音文件识别（短音频优先极速版，否则 submit + query）。"""
    if not Config.VOLC_API_KEY:
        return {"error": "VOLC_API_KEY not configured"}

    try:
        audio_b64, volc_format, pcm_len = prepare_audio_for_volc(
            audio_base64,
            audio_format,
        )
    except Exception as e:
        return {"error": f"ASR audio decode failed: {e}"}

    if pcm_len < int(0.25 * _BYTES_PER_SECOND):
        return {"error": "录音太短，请至少讲 1～2 秒再提交"}

    duration_sec = pcm_len / _BYTES_PER_SECOND
    if duration_sec <= _FLASH_MAX_SECONDS:
        flash = _recognize_flash(audio_b64, volc_format)
        if flash is not None:
            if flash.get("error") or (flash.get("text") or "").strip():
                return flash

    task_id = str(uuid.uuid4())
    headers = {
        "Content-Type": "application/json",
        "X-Api-Key": Config.VOLC_API_KEY,
        "X-Api-Resource-Id": ASR_RESOURCE_ID,
        "X-Api-Request-Id": task_id,
        "X-Api-Sequence": "-1",
    }
    payload = {
        "user": {"uid": "aiic_user"},
        "audio": {"data": audio_b64, "format": volc_format},
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
            "enable_emotion_detection": True,
            "show_speech_rate": True,
            "show_volume": True,
            "show_utterances": True,
        },
    }

    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.post(ASR_SUBMIT_URL, headers=headers, json=payload)

        status_code = resp.headers.get("X-Api-Status-Code", "")
        message = resp.headers.get("X-Api-Message", "")

        if status_code == "20000003":
            return {"error": _friendly_asr_error(status_code, message, phase="submit")}
        if status_code not in ("20000000", "20000001", "20000002"):
            return {"error": _friendly_asr_error(status_code, message, phase="submit")}

        query_headers = {
            "Content-Type": "application/json",
            "X-Api-Key": Config.VOLC_API_KEY,
            "X-Api-Resource-Id": ASR_RESOURCE_ID,
            "X-Api-Request-Id": task_id,
        }

        max_poll = 30
        poll_interval = 0.6

        for _ in range(max_poll):
            time.sleep(poll_interval)
            with httpx.Client(timeout=30.0) as client:
                q_resp = client.post(ASR_QUERY_URL, headers=query_headers, json={})

            q_status = q_resp.headers.get("X-Api-Status-Code", "")
            q_msg = q_resp.headers.get("X-Api-Message", "")

            if q_status == "20000000":
                return _parse_success_body(q_resp.json())
            if q_status == "20000003":
                return {"error": _friendly_asr_error(q_status, q_msg, phase="query")}
            if q_status in ("20000001", "20000002"):
                continue
            return {"error": _friendly_asr_error(q_status, q_msg, phase="query")}

        return {"error": "ASR 识别超时，请重试"}

    except httpx.TimeoutException:
        return {"error": "ASR request timeout"}
    except Exception as e:
        return {"error": f"ASR exception: {str(e)}"}
