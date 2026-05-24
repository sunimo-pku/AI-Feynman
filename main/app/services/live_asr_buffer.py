"""实时讲题 · 音频窗口缓冲。

策略：

- 每个 session 维护 base64 音频 chunk，drain 时先 decode 再合并，避免
  base64 padding 拼接错误。
- 配置 `VOLC_ASR_STREAM_*` 时走 ``VolcStreamingAsrClient``，日志标记
  ``asr_mode=stream``；实时讲题不再把流式 ASR 失败降级成窗口式 ASR。
- ASR 调用失败时由 session 层透传 ``error``，让前端显示真实故障。
"""

from __future__ import annotations

import base64
import logging
from dataclasses import dataclass, field
from typing import Callable

from app.services.volc_asr_stream import VolcStreamingAsrClient

logger = logging.getLogger(__name__)


# 一次 ASR 窗口的音频时长目标（秒）。Brief 建议 2-4s；这里取 2.5s，
# 与 brief "1-3s 出文本"目标互相配合：2.5s 窗口 + 火山 ASR 1-2s 推理
# ≈ 3.5-4s 端到端，再加网络 0.3-0.8s，仍在体感可接受范围内。
_FLUSH_WINDOW_SECONDS = 2.5

# 单次 ASR 窗口允许的最大累积秒数：超过这个就强制 flush，避免学生一直
# 不停顿时音频在内存里无限累加。
_MAX_WINDOW_SECONDS = 6.0

# 单条 chunk 允许的最长 base64 字符串长度（约 2MB 编码后）。
# 第一道防御：恶意 / 走样客户端单 chunk 灌一个 GB 把后端打挂。
_MAX_SINGLE_CHUNK_BYTES = 2 * 1024 * 1024


@dataclass
class _PendingChunk:
    """单条尚未送给 ASR 的音频 chunk。

    我们故意不在内存里 base64-decode：火山 ASR 期望的是 base64 字符串，
    全程保持 base64 形态可以省一次 decode/encode 往返；唯一需要计算的
    是「这段裸音频对应的秒数」，给 16k/16bit/单声道用如下公式估算：

        seconds = base64_decoded_bytes / (sample_rate * bytes_per_sample)
                = (len(b64) * 3 / 4) / (16000 * 2)

    估算误差 ≤ 1 字节 / 16000Hz / 2bytes ≈ 31μs，对我们 2.5s 窗口阈值
    没有任何影响。
    """

    seq: int
    base64_data: str
    sample_rate: int
    seconds: float


@dataclass
class LiveAsrBuffer:
    """每个 live session 一份的音频窗口缓冲。

    并发模型：本类**不**自己加锁；调用方（session 层）已经把所有 WS
    handler 串行在同一个 asyncio task 里跑。"""

    sample_rate: int = 16000
    audio_format: str = "pcm"
    flush_window_seconds: float = _FLUSH_WINDOW_SECONDS
    max_window_seconds: float = _MAX_WINDOW_SECONDS
    _pending: list[_PendingChunk] = field(default_factory=list)
    _pending_seconds: float = 0.0
    _last_seq: int = -1
    stream_client: VolcStreamingAsrClient = field(default_factory=VolcStreamingAsrClient)

    def push(
        self,
        *,
        seq: int,
        base64_data: str,
        sample_rate: int | None = None,
    ) -> None:
        """追加一条来自客户端的 audio_chunk。

        - 仅做最基础校验：base64 非空、长度上限、seq 严格单调。
        - 不做 decode：失败的 base64 字符串会在 ``flush_to_text`` 阶段被
          ``volc_asr.recognize`` 拒绝并打 warning，不让客户端打错单条
          chunk 就把整条 session 杀掉。
        """

        if not base64_data:
            return
        if len(base64_data) > _MAX_SINGLE_CHUNK_BYTES:
            logger.warning(
                "[asr-buffer] 丢弃过大 chunk seq=%d len=%d > %d",
                seq,
                len(base64_data),
                _MAX_SINGLE_CHUNK_BYTES,
            )
            return
        if seq <= self._last_seq:
            logger.warning(
                "[asr-buffer] 丢弃重复或倒退 seq=%d (last=%d)", seq, self._last_seq
            )
            return
        sr = sample_rate or self.sample_rate
        if sr <= 0:
            sr = 16000
        # 16bit/单声道：每秒采样数 * 2 字节。
        bytes_per_second = sr * 2
        try:
            decoded_len = len(base64_data) * 3 // 4
        except Exception:  # noqa: BLE001
            decoded_len = 0
        seconds = decoded_len / bytes_per_second if bytes_per_second else 0.0
        self._pending.append(
            _PendingChunk(
                seq=seq,
                base64_data=base64_data,
                sample_rate=sr,
                seconds=seconds,
            )
        )
        self._pending_seconds += seconds
        self._last_seq = seq

    @property
    def pending_seconds(self) -> float:
        return self._pending_seconds

    @property
    def has_pending(self) -> bool:
        return bool(self._pending)

    def should_flush(self, *, force: bool = False) -> bool:
        """是否到了应该 flush 给 ASR 的窗口边界。"""

        if not self._pending:
            return False
        if force:
            return True
        if self._pending_seconds >= self.flush_window_seconds:
            return True
        if self._pending_seconds >= self.max_window_seconds:
            return True
        return False

    def _drain_windows(self) -> list[tuple[str, float]]:
        """按时长切分 pending chunk，返回多个 base64 音频窗口并清空缓冲。"""

        if not self._pending:
            return []
        # base64 是按 4 字符 1 组的；多个独立 base64 字符串**不能**直接拼接，
        # 必须先 decode 成 bytes 再合并、再 encode。否则中间会出现非法
        # padding，火山 ASR 直接 400。
        windows: list[tuple[bytes, float]] = []
        merged_bytes = bytearray()
        merged_seconds = 0.0
        for chunk in self._pending:
            if (
                merged_bytes
                and merged_seconds + chunk.seconds > self.max_window_seconds
            ):
                windows.append((bytes(merged_bytes), merged_seconds))
                merged_bytes = bytearray()
                merged_seconds = 0.0
            try:
                merged_bytes.extend(base64.b64decode(chunk.base64_data))
                merged_seconds += chunk.seconds
            except Exception as e:  # noqa: BLE001
                logger.warning(
                    "[asr-buffer] base64 decode 失败 seq=%d err=%s; 跳过本 chunk",
                    chunk.seq,
                    e,
                )
        if merged_bytes:
            windows.append((bytes(merged_bytes), merged_seconds))
        self._pending.clear()
        self._pending_seconds = 0.0
        return [
            (base64.b64encode(raw).decode("ascii"), seconds)
            for raw, seconds in windows
            if raw
        ]

    def flush_to_text(
        self,
        recognize_fn: Callable[[str, str], dict],
        *,
        force: bool = False,
    ) -> dict | None:
        """把当前 pending 窗口送给 ``recognize_fn`` 拿到 ASR 结果。

        - ``recognize_fn`` 与 ``app.services.volc_asr.recognize`` 同签名:
          ``(audio_base64, audio_format) -> dict``。注入式设计让我们能在
          单测里替换成 stub，不需要联网。
        - 返回值：
            * ``None``：未达到窗口阈值（除非 ``force=True``），不调用 ASR。
            * ``{"text": "...", "seconds": 2.5, "error": None}``：成功拿到文本。
            * ``{"text": "", "seconds": 2.5, "error": "..."}``：ASR 失败，
              session 层应当继续 listening 状态并通过单独事件透传 warning。
        """

        if not self.should_flush(force=force):
            return None
        windows = self._drain_windows()
        if not windows:
            return None
        total_seconds = sum(seconds for _, seconds in windows)
        texts: list[str] = []
        mode = "stream"
        is_final = True
        try:
            for idx, (b64, seconds) in enumerate(windows, start=1):
                logger.info(
                    "[asr-buffer] flush window part=%d/%d seconds=%.2f b64_len=%d force=%s",
                    idx,
                    len(windows),
                    seconds,
                    len(b64),
                    force,
                )
                stream_result = self.stream_client.recognize_window(
                    audio_base64=b64,
                    audio_format=self.audio_format,
                    recognize_fallback=recognize_fn,
                )
                if stream_result is None:
                    return {
                        "text": "",
                        "seconds": total_seconds,
                        "error": "streaming_asr_not_configured",
                    }
                mode = stream_result.mode
                is_final = is_final and stream_result.is_final
                if stream_result.error:
                    return {
                        "text": "",
                        "seconds": total_seconds,
                        "error": stream_result.error,
                        "mode": stream_result.mode,
                        "isFinal": stream_result.is_final,
                    }
                text_part = stream_result.text.strip()
                if text_part:
                    texts.append(text_part)
            text = " ".join(texts).strip()
            preview = text if len(text) <= 120 else f"{text[:120]}…"
            logger.info(
                "[asr-buffer] flush result text_len=%d preview=%r",
                len(text),
                preview,
            )
            return {
                "text": text,
                "seconds": total_seconds,
                "error": None,
                "mode": mode,
                "isFinal": is_final,
            }
        except Exception as e:  # noqa: BLE001
            logger.exception("[asr-buffer] recognize_fn 抛异常：%s", e)
            return {"text": "", "seconds": total_seconds, "error": f"asr_exception:{e}"}
        if not isinstance(result, dict):
            return {"text": "", "seconds": seconds, "error": "asr_result_not_dict"}
        if result.get("error"):
            return {
                "text": "",
                "seconds": seconds,
                "error": str(result.get("error")),
            }
        text = str(result.get("text") or "").strip()
        return {"text": text, "seconds": seconds, "error": None}

    def reset(self) -> None:
        try:
            self.stream_client.close()
        except Exception:  # noqa: BLE001
            pass
        self._pending.clear()
        self._pending_seconds = 0.0
        self._last_seq = -1
