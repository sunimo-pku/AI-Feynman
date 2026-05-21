"""实时讲题会话状态机（第九轮）。

每条 WebSocket 连接对应一个 ``LiveLectureSession``，负责：

- 维护 ``sessionId / sectionId / questionId / questionPrompt`` 等会话标识；
- 累计学生侧的音频 chunk → ``LiveAsrBuffer`` 输出 ASR 片段；
- 累计学生侧的白板 step snapshot（最新一份覆盖式持有）；
- 维护本题内的 `history`（与 `/lecture/submit` 同口径，最近 6 条）;
- 在收到 ``pause_detected`` 时调用现有 ``lecture_agent.generate_lecture_turns(...)``
  做一次多 Agent 追问，并把结果**拆成流式 delta** 推给前端（每段约 18-22
  汉字一条，给前端"逐步显示"的体感，即便底层 LLM 不是真正 token 流）；
- 在收到 ``student_interrupt`` 时打断本轮 thinking / TTS（state 标志即可，
  TTS 播放由前端控制；后端只负责不再继续推送当前 turn 的剩余 delta）；
- 任意阶段失败时**绝不**让 session 崩溃：只把 warning 通过 ``listening``
  事件透传，让前端继续 listening、复用已有非实时 fallback（前端层面
  可以在 WS 失败时回落到 ``POST /lecture/submit``）。

并发模型：本模块只暴露 ``async`` 方法。路由层把每条 WS 连接放进一个
独立 asyncio task，每个 session 内部所有 handler 串行；ASR / LLM 这种
阻塞 I/O 用 ``run_in_threadpool`` 包一下避免阻塞事件循环。
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

from app.services.live_asr_buffer import LiveAsrBuffer

logger = logging.getLogger(__name__)


# === 事件类型常量（与 brief 第 6 节 1:1 对齐）=================================
# 客户端 → 服务端
EVT_SESSION_START = "session_start"
EVT_AUDIO_CHUNK = "audio_chunk"
EVT_INK_SNAPSHOT = "ink_snapshot"
EVT_PAUSE_DETECTED = "pause_detected"
EVT_STUDENT_INTERRUPT = "student_interrupt"
EVT_SESSION_END = "session_end"

CLIENT_EVENTS: tuple[str, ...] = (
    EVT_SESSION_START,
    EVT_AUDIO_CHUNK,
    EVT_INK_SNAPSHOT,
    EVT_PAUSE_DETECTED,
    EVT_STUDENT_INTERRUPT,
    EVT_SESSION_END,
)

# 服务端 → 客户端
EVT_LISTENING = "listening"
EVT_ASR_SEGMENT = "asr_segment"
EVT_THINKING = "thinking"
EVT_AGENT_TURN_START = "agent_turn_start"
EVT_AGENT_TURN_DELTA = "agent_turn_delta"
EVT_AGENT_TURN_DONE = "agent_turn_done"
EVT_ROUND_DONE = "round_done"
EVT_WARNING = "warning"
EVT_ERROR = "error"


# 单次 LLM 追问产出的整段 text 切成多少字一条 delta 推给前端。
# 经验值：18-22 字一条让流式气泡每 80-120ms 增长一段，体感最接近真实
# token 流；切太碎会让前端 setState 抖动，切太大体感和"等整段"一样。
_DELTA_CHUNK_CHARS = 20

# 同一轮 turn 之间额外停顿，让前端有时间渲染上一条 agent_turn_done。
_INTER_TURN_DELAY_MS = 80

# 单条 delta 之间的间隔，模拟流式生成节奏。
_INTER_DELTA_DELAY_MS = 40

# 一次 thinking → 第一条 delta 之间最少给前端展示"AI 正在想问题"的时长，
# 防御 fallback 路径下 LLM 已经返回但前端来不及切换状态。
_MIN_THINKING_VISIBLE_MS = 240

# 一个 session 内 history 最多保留多少条；与 lecture_agent._HISTORY_KEEP_LAST 同步。
_HISTORY_KEEP_LAST = 6


@dataclass
class _Stroke:
    step_id: str
    stroke_count: int = 0
    latex: str = ""
    plain_text: str = ""
    bounding_box: dict[str, float] | None = None


@dataclass
class LiveLectureSession:
    """一个学生 + 一题的实时讲题会话。"""

    # ---- 会话标识 ----
    session_id: str = ""
    section_id: str = ""
    question_id: str = ""
    question_prompt: str = ""

    # ---- 实时缓冲 ----
    asr_buffer: LiveAsrBuffer = field(default_factory=LiveAsrBuffer)
    transcript_segments: list[str] = field(default_factory=list)
    latest_steps: list[_Stroke] = field(default_factory=list)

    # ---- 状态机 ----
    is_thinking: bool = False
    last_activity_at: float = field(default_factory=time.time)
    history: list[dict[str, Any]] = field(default_factory=list)
    round_index: int = 0

    # ---- 中断 ----
    _interrupt_event: asyncio.Event = field(default_factory=asyncio.Event)
    _started: bool = False

    # ============================================================== #
    # 事件入口
    # ============================================================== #

    async def handle_event(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
        lecture_agent_fn: Callable[..., dict[str, Any]],
        stream_agent_fn: Callable[..., Any] | None = None,
    ) -> bool:
        """处理一条来自客户端的事件。

        返回 ``True`` 表示 session 继续，``False`` 表示客户端要求结束。

        ``send`` / ``recognize_fn`` / ``lecture_agent_fn`` 都用注入式
        设计，方便单测替换。
        """

        evt_type = str(event.get("type") or "").strip()
        if evt_type not in CLIENT_EVENTS:
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": f"unknown event type: {evt_type!r}",
            })
            return True

        self.last_activity_at = time.time()

        if evt_type == EVT_SESSION_START:
            await self._on_session_start(event, send=send)
            return True

        # 后续事件都要求 session 已经 start
        if not self._started:
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "session has not started; ignoring",
            })
            return True

        if evt_type == EVT_AUDIO_CHUNK:
            await self._on_audio_chunk(
                event,
                send=send,
                recognize_fn=recognize_fn,
            )
            return True
        if evt_type == EVT_INK_SNAPSHOT:
            await self._on_ink_snapshot(event, send=send)
            return True
        if evt_type == EVT_PAUSE_DETECTED:
            await self._on_pause_detected(
                event,
                send=send,
                recognize_fn=recognize_fn,
                lecture_agent_fn=lecture_agent_fn,
                stream_agent_fn=stream_agent_fn,
            )
            return True
        if evt_type == EVT_STUDENT_INTERRUPT:
            self._interrupt_event.set()
            await self._safe_send(send, {
                "type": EVT_LISTENING,
                "sessionId": self.session_id,
            })
            return True
        if evt_type == EVT_SESSION_END:
            return False
        return True

    # ============================================================== #
    # 单事件 handler
    # ============================================================== #

    async def _on_session_start(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        self.session_id = str(event.get("sessionId") or self.session_id or uuid.uuid4().hex)
        self.section_id = str(event.get("sectionId") or "").strip()
        self.question_id = str(event.get("questionId") or "").strip()
        self.question_prompt = str(event.get("questionPrompt") or "").strip()
        self._started = True
        self.round_index = 0
        self.history.clear()
        self.transcript_segments.clear()
        self.latest_steps.clear()
        self.asr_buffer.reset()
        self.is_thinking = False
        self._interrupt_event.clear()
        await self._safe_send(send, {
            "type": EVT_LISTENING,
            "sessionId": self.session_id,
        })
        logger.info(
            "[live-session] session_start session=%s section=%s question=%s",
            self.session_id,
            self.section_id,
            self.question_id,
        )

    async def _on_audio_chunk(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
    ) -> None:
        try:
            seq = int(event.get("seq") or 0)
        except (TypeError, ValueError):
            seq = 0
        base64_data = str(event.get("base64") or "")
        try:
            sample_rate = int(event.get("sampleRate") or self.asr_buffer.sample_rate)
        except (TypeError, ValueError):
            sample_rate = self.asr_buffer.sample_rate
        if self.asr_buffer.stream_client.enabled:
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: self.asr_buffer.stream_client.accept_chunk(
                    seq=seq,
                    base64_data=base64_data,
                    recognize_fallback=recognize_fn,
                    force=False,
                ),
            )
            if result is not None and not result.error:
                await self._handle_asr_result(result.__dict__, send=send)
                return
            if result is not None and result.error:
                logger.warning(
                    "[live-session] streaming ASR failed session=%s err=%s; using fallback buffer",
                    self.session_id,
                    result.error,
                )
        self.asr_buffer.push(
            seq=seq,
            base64_data=base64_data,
            sample_rate=sample_rate,
        )
        # 累计满一个窗口就 flush；不阻塞客户端继续发 chunk。
        await self._maybe_flush_asr(send=send, recognize_fn=recognize_fn)

    async def _on_ink_snapshot(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        steps_raw = event.get("steps") or []
        if not isinstance(steps_raw, list):
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "steps is not a list; ignoring snapshot",
            })
            return
        cleaned: list[_Stroke] = []
        for s in steps_raw:
            if not isinstance(s, dict):
                continue
            sid = str(s.get("stepId") or s.get("step_id") or "").strip()
            if not sid:
                continue
            try:
                strokes = int(s.get("strokeCount") or s.get("stroke_count") or 0)
            except (TypeError, ValueError):
                strokes = 0
            bb_raw = s.get("boundingBox") or s.get("bounding_box")
            bb: dict[str, float] | None = None
            if isinstance(bb_raw, dict):
                try:
                    bb = {
                        "x": float(bb_raw.get("x", 0) or 0),
                        "y": float(bb_raw.get("y", 0) or 0),
                        "width": float(bb_raw.get("width", 0) or 0),
                        "height": float(bb_raw.get("height", 0) or 0),
                    }
                except (TypeError, ValueError):
                    bb = None
            cleaned.append(
                _Stroke(
                    step_id=sid,
                    stroke_count=max(0, strokes),
                    latex=str(s.get("latex") or "").strip(),
                    plain_text=str(s.get("plainText") or s.get("plain_text") or "").strip(),
                    bounding_box=bb,
                )
            )
        self.latest_steps = cleaned

    async def _on_pause_detected(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
        lecture_agent_fn: Callable[..., dict[str, Any]],
        stream_agent_fn: Callable[..., Any] | None = None,
    ) -> None:
        if self.is_thinking:
            # brief 第 12 节："同一轮追问生成中忽略重复触发"
            await self._safe_send(send, {
                "type": EVT_THINKING,
                "sessionId": self.session_id,
            })
            return
        if not self.latest_steps:
            # 白板还没东西，老师追问的根都没有 —— 提示学生先写两步再继续。
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "no_steps_yet",
            })
            return
        # 进入 thinking 前先把剩余音频 flush 给 ASR；这样 LLM 看到的
        # studentSpeechText 包含学生静音前的最后一两句话。
        await self._maybe_flush_asr(
            send=send,
            recognize_fn=recognize_fn,
            force=True,
        )
        self.is_thinking = True
        self._interrupt_event.clear()
        await self._safe_send(send, {
            "type": EVT_THINKING,
            "sessionId": self.session_id,
        })
        thinking_start_ms = time.monotonic() * 1000

        try:
            if stream_agent_fn is not None:
                response = await self._stream_agent_events_to_client(
                    stream_agent_fn,
                    send=send,
                )
            else:
                response = await self._invoke_lecture_agent(lecture_agent_fn)
        except Exception as e:  # noqa: BLE001
            logger.exception("[live-session] lecture_agent 失败：%s", e)
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "agent_unavailable",
            })
            self.is_thinking = False
            await self._safe_send(send, {
                "type": EVT_LISTENING,
                "sessionId": self.session_id,
            })
            return

        # 保证 thinking 状态至少可见一段时间，避免 fallback 路径下
        # 前端 thinking → done 切换过快显得"假"。
        elapsed_ms = time.monotonic() * 1000 - thinking_start_ms
        if elapsed_ms < _MIN_THINKING_VISIBLE_MS:
            await asyncio.sleep((_MIN_THINKING_VISIBLE_MS - elapsed_ms) / 1000)

        if stream_agent_fn is None:
            await self._stream_turns_to_client(response, send=send)

        # 落 history。先 student 一条（来自当前 transcript_segments），
        # 再依次落 AI turns。
        self._append_student_history_snapshot()
        for t in response.get("turns", []):
            self.history.append({
                "role": str(t.get("role") or "system"),
                "displayName": str(t.get("display_name") or ""),
                "text": str(t.get("text") or ""),
                "highlightStepIds": list(t.get("highlight_step_ids") or []),
            })
        if len(self.history) > _HISTORY_KEEP_LAST:
            del self.history[: len(self.history) - _HISTORY_KEEP_LAST]
        self.round_index += 1
        self.is_thinking = False

        await self._safe_send(send, {
            "type": EVT_ROUND_DONE,
            "sessionId": self.session_id,
            "status": response.get("status", "needs_explanation"),
            "masteryDelta": int(response.get("mastery_delta", 0) or 0),
        })
        await self._safe_send(send, {
            "type": EVT_LISTENING,
            "sessionId": self.session_id,
        })

    # ============================================================== #
    # 内部辅助
    # ============================================================== #

    async def _maybe_flush_asr(
        self,
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
        force: bool = False,
    ) -> None:
        if self.asr_buffer.stream_client.enabled:
            if not force:
                return
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: self.asr_buffer.stream_client.accept_chunk(
                    seq=-1,
                    base64_data="",
                    recognize_fallback=recognize_fn,
                    force=True,
                ),
            )
            if result is not None:
                await self._handle_asr_result(result.__dict__, send=send)
            return
        if not self.asr_buffer.should_flush(force=force):
            return
        # ASR 是阻塞 I/O，丢到 threadpool 跑。
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            None,
            lambda: self.asr_buffer.flush_to_text(recognize_fn, force=force),
        )
        if result is None:
            return
        await self._handle_asr_result(result, send=send)

    async def _handle_asr_result(
        self,
        result: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        if result.get("error"):
            logger.warning(
                "[live-session] ASR window failed session=%s err=%s",
                self.session_id,
                result.get("error"),
            )
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "asr_window_failed",
            })
            return
        text = (result.get("text") or "").strip()
        if not text:
            return
        self.transcript_segments.append(text)
        await self._safe_send(send, {
            "type": EVT_ASR_SEGMENT,
            "sessionId": self.session_id,
            "text": text,
        })

    async def _invoke_lecture_agent(
        self,
        lecture_agent_fn: Callable[..., dict[str, Any]],
    ) -> dict[str, Any]:
        steps_payload = [
            {
                "stepId": s.step_id,
                "latex": s.latex,
                "plainText": s.plain_text,
                "strokeCount": s.stroke_count,
            }
            for s in self.latest_steps
        ]
        speech = " ".join(self.transcript_segments[-6:]).strip()
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            None,
            lambda: lecture_agent_fn(
                section_id=self.section_id,
                question_id=self.question_id,
                question_prompt=self.question_prompt,
                student_speech_text=speech,
                steps=steps_payload,
                round_index=max(1, self.round_index + 1),
                history=list(self.history),
            ),
        )

    async def _stream_turns_to_client(
        self,
        response: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        turns = response.get("turns") or []
        for idx, t in enumerate(turns):
            if self._interrupt_event.is_set():
                # 学生打断 — 中止剩余 turn 推送。
                return
            turn_id = str(t.get("turn_id") or f"turn_{idx + 1}")
            role = str(t.get("role") or "system")
            display = str(t.get("display_name") or "")
            highlight = list(t.get("highlight_step_ids") or [])
            text = str(t.get("text") or "")
            await self._safe_send(send, {
                "type": EVT_AGENT_TURN_START,
                "sessionId": self.session_id,
                "turnId": turn_id,
                "role": role,
                "displayName": display,
                "highlightStepIds": highlight,
            })
            for delta in _split_text_into_deltas(text, _DELTA_CHUNK_CHARS):
                if self._interrupt_event.is_set():
                    break
                await self._safe_send(send, {
                    "type": EVT_AGENT_TURN_DELTA,
                    "sessionId": self.session_id,
                    "turnId": turn_id,
                    "delta": delta,
                })
                await asyncio.sleep(_INTER_DELTA_DELAY_MS / 1000)
            await self._safe_send(send, {
                "type": EVT_AGENT_TURN_DONE,
                "sessionId": self.session_id,
                "turnId": turn_id,
            })
            await asyncio.sleep(_INTER_TURN_DELAY_MS / 1000)

    async def _stream_agent_events_to_client(
        self,
        stream_agent_fn: Callable[..., Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> dict[str, Any]:
        steps_payload = [
            {
                "stepId": s.step_id,
                "latex": s.latex,
                "plainText": s.plain_text,
                "strokeCount": s.stroke_count,
            }
            for s in self.latest_steps
        ]
        speech = " ".join(self.transcript_segments[-6:]).strip()
        turns_by_id: dict[str, dict[str, Any]] = {}
        order: list[str] = []
        status = "needs_explanation"
        mastery_delta = 0
        for event in stream_agent_fn(
            section_id=self.section_id,
            question_id=self.question_id,
            question_prompt=self.question_prompt,
            student_speech_text=speech,
            steps=steps_payload,
            round_index=max(1, self.round_index + 1),
            history=list(self.history),
        ):
            if self._interrupt_event.is_set():
                break
            typ = str(event.get("type") or "")
            if typ == "turn_start":
                turn_id = str(event.get("turnId") or f"turn_{len(order) + 1}")
                order.append(turn_id)
                turns_by_id[turn_id] = {
                    "turn_id": turn_id,
                    "role": str(event.get("role") or "teacher"),
                    "display_name": str(event.get("displayName") or "李老师"),
                    "text": "",
                    "highlight_step_ids": list(event.get("highlightStepIds") or []),
                }
                await self._safe_send(send, {
                    "type": EVT_AGENT_TURN_START,
                    "sessionId": self.session_id,
                    "turnId": turn_id,
                    "role": turns_by_id[turn_id]["role"],
                    "displayName": turns_by_id[turn_id]["display_name"],
                    "highlightStepIds": turns_by_id[turn_id]["highlight_step_ids"],
                })
            elif typ == "delta":
                turn_id = str(event.get("turnId") or (order[-1] if order else "turn_1"))
                delta = str(event.get("delta") or "")
                turns_by_id.setdefault(turn_id, {
                    "turn_id": turn_id,
                    "role": "teacher",
                    "display_name": "李老师",
                    "text": "",
                    "highlight_step_ids": [self.latest_steps[0].step_id] if self.latest_steps else [],
                })
                turns_by_id[turn_id]["text"] += delta
                await self._safe_send(send, {
                    "type": EVT_AGENT_TURN_DELTA,
                    "sessionId": self.session_id,
                    "turnId": turn_id,
                    "delta": delta,
                })
            elif typ == "turn_done":
                await self._safe_send(send, {
                    "type": EVT_AGENT_TURN_DONE,
                    "sessionId": self.session_id,
                    "turnId": str(event.get("turnId") or (order[-1] if order else "turn_1")),
                })
            elif typ == "round_meta":
                status = str(event.get("status") or status)
                try:
                    mastery_delta = int(event.get("masteryDelta") or 0)
                except (TypeError, ValueError):
                    mastery_delta = 0
        turns = [turns_by_id[k] for k in order if k in turns_by_id]
        return {
            "status": status,
            "mastery_delta": mastery_delta,
            "turns": turns,
            "source": "llm_stream",
        }

    def _append_student_history_snapshot(self) -> None:
        speech = " ".join(self.transcript_segments[-6:]).strip()
        steps_summary_bits: list[str] = []
        for s in self.latest_steps:
            descr_parts: list[str] = []
            if s.plain_text:
                descr_parts.append(s.plain_text)
            if s.latex:
                descr_parts.append(f"`{s.latex}`")
            if not descr_parts:
                descr_parts.append(f"{s.stroke_count} 笔")
            steps_summary_bits.append(f"{s.step_id}: " + "; ".join(descr_parts))
        parts: list[str] = []
        if speech:
            parts.append(speech)
        if steps_summary_bits:
            parts.append("（白板步骤）" + "；".join(steps_summary_bits))
        if not parts:
            parts.append("（学生本轮没有有效语音或步骤）")
        self.history.append({
            "role": "student",
            "displayName": "我",
            "text": " ".join(parts),
            "highlightStepIds": [s.step_id for s in self.latest_steps],
        })

    async def _safe_send(
        self,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        payload: dict[str, Any],
    ) -> None:
        try:
            await send(payload)
        except Exception as e:  # noqa: BLE001
            logger.warning(
                "[live-session] send 失败 type=%s err=%s",
                payload.get("type"),
                e,
            )


def _split_text_into_deltas(text: str, chunk_chars: int) -> list[str]:
    """把整段 turn text 切成若干段 delta，每段约 ``chunk_chars`` 个字符。

    第一版按字符数硬切，不做句末对齐 —— Brief 第 5 节明确要求"流式追问
    开始后，前端应逐步显示，而不是等整段结束才出现"，体感优先于"在
    标点处优雅断行"。中文 + 英文混排时按 unicode 字符切，不会把
    surrogate 对切坏。
    """

    if not text:
        return []
    if chunk_chars <= 0:
        return [text]
    out: list[str] = []
    buf: list[str] = []
    for ch in text:
        buf.append(ch)
        if len(buf) >= chunk_chars:
            out.append("".join(buf))
            buf.clear()
    if buf:
        out.append("".join(buf))
    return out
