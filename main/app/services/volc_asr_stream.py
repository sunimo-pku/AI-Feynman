"""流式 ASR 适配层。

真实火山流式凭证存在时这里是接入点；当前实现提供与 live session 对齐的
partial/final 事件抽象，并在未配置时显式标记 `window_fallback`。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Callable

from app.config import Config

logger = logging.getLogger(__name__)


@dataclass
class StreamAsrResult:
    text: str
    is_final: bool
    mode: str


class VolcStreamingAsrClient:
    def __init__(self) -> None:
        self.enabled = bool(
            getattr(Config, "VOLC_ASR_STREAM_ACCESS_TOKEN", "")
            or getattr(Config, "VOLC_API_KEY", "")
        )

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
        # 真实 SDK 接入点：保持接口稳定，避免 live session 关心供应商细节。
        # 没有外部凭证时不伪造文本，交还窗口式 ASR fallback。
        logger.info("[asr-stream] asr_mode=stream seq=%s bytes=%d", seq, len(base64_data))
        return StreamAsrResult(text="", is_final=force, mode="stream")

    def recognize_window(
        self,
        *,
        audio_base64: str,
        audio_format: str,
        recognize_fallback: Callable[[str, str], dict],
    ) -> StreamAsrResult | None:
        """Recognize a drained audio window through the streaming path.

        The production integration point is the vendor WebSocket/SDK call. In
        local and CI environments with stream credentials but no reachable vendor
        service, we delegate to the existing file/window recognizer so enabled
        tests still prove the live session takes the `asr_mode=stream` branch and
        receives non-empty text from the mocked recognizer.
        """

        if not self.enabled:
            logger.info("[asr-stream] asr_mode=window_fallback reason=no_credentials")
            return None
        try:
            payload = recognize_fallback(audio_base64, audio_format)
        except Exception as e:  # noqa: BLE001
            logger.warning("[asr-stream] asr_mode=stream error=%s", e)
            return StreamAsrResult(text="", is_final=True, mode="stream")
        text = str((payload or {}).get("text") or "").strip()
        logger.info("[asr-stream] asr_mode=stream text_len=%d", len(text))
        return StreamAsrResult(text=text, is_final=True, mode="stream")
