"""火山大模型流式 ASR 适配层。

新版控制台走 ``X-Api-Key`` 鉴权，WebSocket payload 使用火山专用二进制
协议：4 字节 header + payload size + gzip payload。这里把实时讲题已经
收到的 PCM 窗口送到 ``bigmodel_async``，拿到流式 ASR 文本；未配置流式
资源或调用失败时由上层继续走窗口式 fallback。
"""

from __future__ import annotations

import base64
import gzip
import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Any, Callable

from websockets.sync.client import connect as ws_connect
from websockets.exceptions import WebSocketException

from app.config import Config

logger = logging.getLogger(__name__)

_VERSION = 0x1
_HEADER_SIZE = 0x1
_MSG_FULL_CLIENT_REQUEST = 0x1
_MSG_AUDIO_ONLY_REQUEST = 0x2
_MSG_FULL_SERVER_RESPONSE = 0x9
_MSG_ERROR = 0xF
_FLAG_NONE = 0x0
_FLAG_LAST_NO_SEQUENCE = 0x2
_SERIALIZATION_NONE = 0x0
_SERIALIZATION_JSON = 0x1
_COMPRESSION_NONE = 0x0
_COMPRESSION_GZIP = 0x1


@dataclass
class StreamAsrResult:
    text: str
    is_final: bool
    mode: str
    error: str | None = None


class VolcStreamingAsrClient:
    """Small synchronous client for Volc ``sauc/bigmodel_async``.

    ``LiveLectureSession`` already runs ASR in a threadpool, so this client stays
    synchronous and keeps the rest of the session code simple.
    """

    def __init__(
        self,
        *,
        api_key: str | None = None,
        resource_id: str | None = None,
        url: str | None = None,
        timeout_seconds: float | None = None,
        connector: Callable[..., Any] = ws_connect,
    ) -> None:
        self.api_key = _clean_secret(
            api_key
            if api_key is not None
            else getattr(Config, "VOLC_ASR_STREAM_API_KEY", "")
        )
        self.resource_id = (
            resource_id
            if resource_id is not None
            else getattr(Config, "VOLC_ASR_STREAM_RESOURCE_ID", "")
        ).strip()
        self.url = (
            url
            if url is not None
            else getattr(Config, "VOLC_ASR_STREAM_URL", "")
        ).strip()
        self.timeout_seconds = float(
            timeout_seconds
            if timeout_seconds is not None
            else getattr(Config, "VOLC_ASR_STREAM_TIMEOUT_SECONDS", 8)
        )
        self._connector = connector
        self.enabled = bool(self.api_key and self.resource_id and self.url)
        self._ws: Any | None = None
        self._sample_rate = 16000

    def accept_chunk(
        self,
        *,
        seq: int,
        base64_data: str,
        recognize_fallback: Callable[[str, str], dict],
        force: bool = False,
    ) -> StreamAsrResult | None:
        if not self.enabled:
            return None
        if force and not base64_data and self._ws is None:
            return None
        try:
            audio_bytes = base64.b64decode(base64_data)
        except Exception as e:  # noqa: BLE001
            return StreamAsrResult(text="", is_final=force, mode="stream", error=f"bad_base64:{e}")
        return self._recognize_audio_bytes(
            audio_bytes,
            sample_rate=16000,
            force_final=force,
            keep_open=not force,
        )

    def recognize_window(
        self,
        *,
        audio_base64: str,
        audio_format: str,
        recognize_fallback: Callable[[str, str], dict],
    ) -> StreamAsrResult | None:
        """Recognize a drained PCM window through Volc streaming ASR."""

        if not self.enabled:
            logger.info("[asr-stream] asr_mode=window_fallback reason=no_credentials")
            return None
        try:
            audio_bytes = base64.b64decode(audio_base64)
        except Exception as e:  # noqa: BLE001
            return StreamAsrResult(text="", is_final=True, mode="stream", error=f"bad_base64:{e}")
        if audio_format not in ("pcm", "pcm16", "wav"):
            logger.info("[asr-stream] audio_format=%s passed through as pcm", audio_format)
        return self._recognize_audio_bytes(
            audio_bytes,
            sample_rate=16000,
            force_final=True,
            keep_open=False,
        )

    def close(self) -> None:
        ws = self._ws
        self._ws = None
        if ws is None:
            return
        try:
            ws.close()
        except Exception:  # noqa: BLE001
            pass

    def _recognize_audio_bytes(
        self,
        audio_bytes: bytes,
        *,
        sample_rate: int,
        force_final: bool,
        keep_open: bool,
    ) -> StreamAsrResult:
        if not audio_bytes and not force_final:
            return StreamAsrResult(text="", is_final=force_final, mode="stream")
        started = time.monotonic()
        try:
            ws = self._ensure_connection(sample_rate=sample_rate)
            ws.send(_audio_request_frame(audio_bytes, is_last=force_final))
            text, is_final = self._collect_responses(ws, wait_for_final=force_final)
        except (OSError, TimeoutError, WebSocketException, RuntimeError) as e:
            self.close()
            logger.warning("[asr-stream] asr_mode=stream failed err=%s", e)
            return StreamAsrResult(
                text="",
                is_final=True,
                mode="stream",
                error=f"asr_stream_exception:{e}",
            )
        finally:
            if force_final or not keep_open:
                self.close()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        logger.info(
            "[asr-stream] asr_mode=stream text_len=%d final=%s elapsed_ms=%d",
            len(text),
            is_final,
            elapsed_ms,
        )
        return StreamAsrResult(text=text, is_final=is_final or force_final, mode="stream")

    def _ensure_connection(self, *, sample_rate: int) -> Any:
        if self._ws is not None:
            return self._ws
        request_id = str(uuid.uuid4())
        headers = {
            "X-Api-Key": self.api_key,
            "X-Api-Resource-Id": self.resource_id,
            "X-Api-Request-Id": request_id,
            "X-Api-Connect-Id": request_id,
            "X-Api-Sequence": "-1",
        }
        ws = self._connector(
            self.url,
            additional_headers=headers,
            open_timeout=self.timeout_seconds,
            close_timeout=self.timeout_seconds,
        )
        if hasattr(ws, "__enter__"):
            ws = ws.__enter__()
        ws.send(_full_client_request_frame(sample_rate=sample_rate))
        self._ws = ws
        self._sample_rate = sample_rate
        return ws

    def _collect_responses(self, ws: Any, *, wait_for_final: bool) -> tuple[str, bool]:
        wait_seconds = self.timeout_seconds if wait_for_final else min(0.2, self.timeout_seconds)
        deadline = time.monotonic() + wait_seconds
        best_text = ""
        final_seen = False
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            try:
                raw = ws.recv(timeout=remaining)
            except TimeoutError:
                break
            parsed = _parse_server_frame(raw)
            if parsed.text:
                best_text = parsed.text
            if parsed.is_final:
                final_seen = True
                break
        return best_text.strip(), final_seen


@dataclass
class _ParsedServerFrame:
    text: str
    is_final: bool


def _clean_secret(value: str | None) -> str:
    raw = (value or "").strip()
    if not raw or raw.startswith("your_"):
        return ""
    return raw


def _header(
    *,
    message_type: int,
    flags: int,
    serialization: int,
    compression: int,
) -> bytes:
    return bytes([
        (_VERSION << 4) | _HEADER_SIZE,
        (message_type << 4) | flags,
        (serialization << 4) | compression,
        0x00,
    ])


def _frame(
    *,
    message_type: int,
    flags: int,
    serialization: int,
    compression: int,
    payload: bytes,
) -> bytes:
    return (
        _header(
            message_type=message_type,
            flags=flags,
            serialization=serialization,
            compression=compression,
        )
        + len(payload).to_bytes(4, "big", signed=False)
        + payload
    )


def _full_client_request_frame(*, sample_rate: int) -> bytes:
    payload = {
        "user": {"uid": "ai-feynman-backend"},
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": sample_rate,
            "bits": 16,
            "channel": 1,
            "language": "zh-CN",
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
            "enable_ddc": False,
            "enable_nonstream": True,
            "show_utterances": True,
            "result_type": "full",
            "end_window_size": 800,
            "force_to_speech_time": 1000,
        },
    }
    data = gzip.compress(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    return _frame(
        message_type=_MSG_FULL_CLIENT_REQUEST,
        flags=_FLAG_NONE,
        serialization=_SERIALIZATION_JSON,
        compression=_COMPRESSION_GZIP,
        payload=data,
    )


def _audio_request_frame(audio_bytes: bytes, *, is_last: bool) -> bytes:
    return _frame(
        message_type=_MSG_AUDIO_ONLY_REQUEST,
        flags=_FLAG_LAST_NO_SEQUENCE if is_last else _FLAG_NONE,
        serialization=_SERIALIZATION_NONE,
        compression=_COMPRESSION_GZIP,
        payload=gzip.compress(audio_bytes),
    )


def _parse_server_frame(raw: bytes | bytearray | str) -> _ParsedServerFrame:
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    data = bytes(raw)
    if len(data) < 8:
        raise RuntimeError("volc_stream_frame_too_short")
    header_size = (data[0] & 0x0F) * 4
    message_type = data[1] >> 4
    flags = data[1] & 0x0F
    serialization = data[2] >> 4
    compression = data[2] & 0x0F
    offset = header_size
    if message_type == _MSG_ERROR:
        if len(data) < offset + 8:
            raise RuntimeError("volc_stream_error_frame_too_short")
        code = int.from_bytes(data[offset:offset + 4], "big", signed=False)
        size = int.from_bytes(data[offset + 4:offset + 8], "big", signed=False)
        message = data[offset + 8:offset + 8 + size].decode("utf-8", errors="replace")
        raise RuntimeError(f"volc_stream_error:{code}:{message}")
    if message_type != _MSG_FULL_SERVER_RESPONSE:
        return _ParsedServerFrame(text="", is_final=False)
    if flags in (0x1, 0x3):
        offset += 4
    if len(data) < offset + 4:
        raise RuntimeError("volc_stream_payload_size_missing")
    payload_size = int.from_bytes(data[offset:offset + 4], "big", signed=False)
    offset += 4
    payload = data[offset:offset + payload_size]
    if compression == _COMPRESSION_GZIP:
        payload = gzip.decompress(payload)
    if serialization != _SERIALIZATION_JSON:
        return _ParsedServerFrame(text=payload.decode("utf-8", errors="ignore"), is_final=flags in (0x2, 0x3))
    if not payload.strip():
        return _ParsedServerFrame(text="", is_final=flags in (0x2, 0x3))
    body = json.loads(payload.decode("utf-8"))
    text, definite = _extract_text(body)
    return _ParsedServerFrame(text=text, is_final=definite or flags in (0x2, 0x3))


def _extract_text(body: Any) -> tuple[str, bool]:
    if not isinstance(body, dict):
        return "", False
    result = body.get("result") or {}
    if isinstance(result, list):
        result = result[-1] if result else {}
    if not isinstance(result, dict):
        return "", False
    text = str(result.get("text") or "").strip()
    definite = False
    utterances = result.get("utterances")
    if isinstance(utterances, list):
        for item in utterances:
            if isinstance(item, dict) and item.get("definite") is True:
                definite = True
                item_text = str(item.get("text") or "").strip()
                if item_text:
                    text = item_text if not text else text
    return text, definite
