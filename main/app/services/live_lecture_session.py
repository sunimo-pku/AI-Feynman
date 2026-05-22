"""实时讲题会话状态机（第九轮）。

每条 WebSocket 连接对应一个 ``LiveLectureSession``，负责：

- 维护 ``sessionId / sectionId / questionId / questionPrompt`` 等会话标识；
- 累计学生侧的音频 chunk → ``LiveAsrBuffer`` 输出 ASR 片段；
- 累计学生侧的白板 step snapshot（最新一份覆盖式持有）；
- 维护本题内的 `history`（与 `/lecture/submit` 同口径，最近 6 条）;
- 在收到 ``pause_detected`` 时调用 ``peer_assessment_agent.generate_peer_assessments(...)``
  并行评估三名同伴；全员听懂时再调 ``teacher_agent.generate_teacher_summary``；
  通过 ``peer_assessments`` 事件把评估结果一次性推给前端（与 ``/lecture/submit`` 同口径）。
- 在收到 ``student_interrupt`` 时打断本轮 thinking / TTS（state 标志即可，
  TTS 播放由前端控制；后端只负责不再继续推送当前 turn 的剩余 delta）；
- 任意核心阶段失败时发送 ``error`` 事件，不再静默降级；warning 只用于
  非致命协议提示。

并发模型：本模块只暴露 ``async`` 方法。路由层把每条 WS 连接放进一个
独立 asyncio task，每个 session 内部所有 handler 串行；ASR / LLM 这种
阻塞 I/O 用 ``run_in_threadpool`` 包一下避免阻塞事件循环。
"""

from __future__ import annotations

import asyncio
import base64
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
EVT_REQUEST_HINT = "request_hint"
EVT_SESSION_END = "session_end"
# 应用层 client→server 心跳：客户端 20s 一次发一个，目的是让运营商
# NAT 看到上行流量，避免 60-90s 静默期被中间设备单边关连接。后端
# 收到后只刷新 last_activity_at、不打 warning，也不要求 session 已 start。
EVT_PING = "ping"

CLIENT_EVENTS: tuple[str, ...] = (
    EVT_SESSION_START,
    EVT_AUDIO_CHUNK,
    EVT_INK_SNAPSHOT,
    EVT_PAUSE_DETECTED,
    EVT_STUDENT_INTERRUPT,
    EVT_REQUEST_HINT,
    EVT_SESSION_END,
    EVT_PING,
)

# 服务端 → 客户端
EVT_LISTENING = "listening"
EVT_ASR_SEGMENT = "asr_segment"
EVT_THINKING = "thinking"
EVT_AGENT_TURN_START = "agent_turn_start"
EVT_AGENT_TURN_DELTA = "agent_turn_delta"
EVT_AGENT_TURN_DONE = "agent_turn_done"
EVT_ROUND_DONE = "round_done"
EVT_PEER_ASSESSMENTS = "peer_assessments"
# 单名同伴评估完成即推送（早于整包 peer_assessments），便于 UI 先更新头像环。
EVT_PEER_ASSESSMENT_ITEM = "peer_assessment_item"
EVT_WARNING = "warning"
EVT_ERROR = "error"
# 第十二轮第三轮（流式 TTS）：LLM 流式 delta 累积一句完整中文（句号 / 问号 / 感叹号）
# 后立刻调火山流式 TTS，每段 mp3 bytes base64 一发就推。前端按 turnId 累积、
# 按 seq 顺序播放（首段直接播，后续段排队）。failure 时只 warning，不影响气泡显示。
EVT_AGENT_TTS_CHUNK = "agent_tts_chunk"


# 单次 LLM 追问产出的整段 text 切成多少字一条 delta 推给前端。
# 仅用于 _stream_turns_to_client（备用同步路径）；流式主路径由 LLM
# 自己控制 delta 粒度，不走这个常量。
_DELTA_CHUNK_CHARS = 20

# 同一轮 turn 之间额外停顿。第十二轮第二轮调优：80ms → 0；让 turn_done
# → next turn_start 之间无人为延迟。备用路径才用得到。
_INTER_TURN_DELAY_MS = 0

# 单条 delta 之间的间隔。第十二轮第二轮调优：40ms → 0。流式主路径根本
# 不应该有人为 sleep —— LLM 给一段就推一段，对话感才出来。备用路径才
# 用得到。
_INTER_DELTA_DELAY_MS = 0

# thinking 状态最短可见时长。第十二轮第二轮调优：240ms → 0。原本是
# 防御「LLM 极快返回，前端没来得及切 thinking 就要切 aiSpeaking」，
# 但用户反馈整体延迟过高 —— 这种场景目前根本不会出现，反而 240ms
# 是白白挤压第一条气泡的可见时间。
_MIN_THINKING_VISIBLE_MS = 0

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
    last_status: str = "needs_explanation"
    last_mastery_delta: int = 0

    # ---- 中断 ----
    _interrupt_event: asyncio.Event = field(default_factory=asyncio.Event)
    _started: bool = False

    # ---- 流式 TTS（第十二轮第三轮）----
    # 在 delta 累积时按中文标点切句，每完整一句异步调火山流式 TTS，
    # mp3 bytes base64 通过 ws `agent_tts_chunk` 推给前端。
    # `_tts_seq_by_turn` 只在主协程里递增，保证 (turnId, seq) 全局有序。
    _tts_buffer_by_turn: dict[str, str] = field(default_factory=dict)
    _tts_seq_by_turn: dict[str, int] = field(default_factory=dict)
    _tts_role_by_turn: dict[str, str] = field(default_factory=dict)
    _tts_tail_by_turn: dict[str, asyncio.Task] = field(default_factory=dict)
    # 每轮「讲题结束」只消费此索引之后的 ASR 片段，避免上一轮语音混入本轮。
    _transcript_round_start: int = 0

    def _current_round_speech(self) -> str:
        return " ".join(
            self.transcript_segments[self._transcript_round_start :]
        ).strip()

    def _mark_transcript_round_consumed(self) -> None:
        self._transcript_round_start = len(self.transcript_segments)

    # ============================================================== #
    # 事件入口
    # ============================================================== #

    async def handle_event(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
        peer_assessment_fn: Callable[..., dict[str, Any]],
        teacher_summary_fn: Callable[..., dict[str, Any]] | None = None,
        teacher_hint_fn: Callable[..., dict[str, Any]] | None = None,
    ) -> bool:
        """处理一条来自客户端的事件。

        返回 ``True`` 表示 session 继续，``False`` 表示客户端要求结束。

        ``send`` / ``recognize_fn`` / ``peer_assessment_fn`` 都用注入式
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

        # 应用层心跳：在 session_start 之前也允许（客户端可能在连接握手
        # 完成后还没来得及发 session_start 就先 ping），不回任何事件，
        # 只更新 last_activity_at 即可。
        if evt_type == EVT_PING:
            return True

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
                peer_assessment_fn=peer_assessment_fn,
                teacher_summary_fn=teacher_summary_fn,
            )
            return True
        if evt_type == EVT_STUDENT_INTERRUPT:
            self._interrupt_event.set()
            await self._safe_send(send, {
                "type": EVT_LISTENING,
                "sessionId": self.session_id,
            })
            return True
        if evt_type == EVT_REQUEST_HINT:
            await self._on_request_hint(
                send=send,
                teacher_hint_fn=teacher_hint_fn,
            )
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
        self._transcript_round_start = 0
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
                await self._send_error(send, f"streaming_asr_failed:{result.error}")
                return
        await self._send_error(send, "streaming_asr_not_configured")

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
        # 第十二轮：no_steps_yet 故障线索几乎都是「新 session 没收到 snapshot」。
        # 加一条 info 日志，下次出问题立刻能看到「snapshot 到了哪个 session
        # 几步」，与 pause_detected 的时间戳对齐就能定位。
        logger.info(
            "[live-session] ink_snapshot session=%s steps=%d",
            self.session_id,
            len(cleaned),
        )

    async def _on_pause_detected(
        self,
        event: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        recognize_fn: Callable[[str, str], dict],
        peer_assessment_fn: Callable[..., dict[str, Any]],
        teacher_summary_fn: Callable[..., dict[str, Any]] | None = None,
    ) -> None:
        if self.is_thinking:
            await self._safe_send(send, {
                "type": EVT_THINKING,
                "sessionId": self.session_id,
            })
            return
        has_speech = any(seg.strip() for seg in self.transcript_segments)
        if not self.latest_steps and not has_speech:
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "no_steps_yet",
            })
            await self._safe_send(send, {
                "type": EVT_LISTENING,
                "sessionId": self.session_id,
            })
            return
        pause_t0 = time.monotonic()
        await self._maybe_flush_asr(
            send=send,
            recognize_fn=recognize_fn,
            force=True,
        )
        asr_ms = (time.monotonic() - pause_t0) * 1000
        logger.info(
            "[live-session] pause asr_flush_ms=%.0f session=%s",
            asr_ms,
            self.session_id,
        )
        self.is_thinking = True
        self._interrupt_event.clear()
        await self._safe_send(send, {
            "type": EVT_THINKING,
            "sessionId": self.session_id,
        })
        thinking_start_ms = time.monotonic() * 1000
        phase_t0 = time.monotonic()

        try:
            result = await self._invoke_peer_assessments_streaming(
                peer_assessment_fn=peer_assessment_fn,
                send=send,
            )
        except Exception as e:  # noqa: BLE001
            logger.exception("[live-session] peer_assessment 失败：%s", e)
            await self._send_error(send, f"peer_assessment_failed:{e}")
            self.is_thinking = False
            return

        peer_ms = (time.monotonic() - phase_t0) * 1000
        logger.info(
            "[live-session] pause pipeline peer_ms=%.0f session=%s",
            peer_ms,
            self.session_id,
        )

        assessments = list(result.get("assessments") or [])
        all_understood = bool(result.get("all_understood"))
        status = str(result.get("status") or "needs_explanation")
        mastery_delta = int(result.get("mastery_delta") or 0)

        teacher_summary: dict[str, Any] | None = None
        teacher_ms = 0.0
        if all_understood and teacher_summary_fn is not None:
            teacher_t0 = time.monotonic()
            try:
                teacher_summary = await self._invoke_teacher_summary(
                    teacher_summary_fn,
                    peer_assessments=assessments,
                )
            except Exception as e:  # noqa: BLE001
                logger.exception("[live-session] teacher_summary 失败：%s", e)
                await self._send_error(send, f"teacher_summary_failed:{e}")
                self.is_thinking = False
                return
            teacher_ms = (time.monotonic() - teacher_t0) * 1000

        elapsed_ms = time.monotonic() * 1000 - thinking_start_ms
        if elapsed_ms < _MIN_THINKING_VISIBLE_MS:
            await asyncio.sleep((_MIN_THINKING_VISIBLE_MS - elapsed_ms) / 1000)

        await self._safe_send(send, {
            "type": EVT_PEER_ASSESSMENTS,
            "sessionId": self.session_id,
            "assessments": [_assessment_to_wire(a) for a in assessments],
            "allUnderstood": all_understood,
            "status": status,
            "masteryDelta": mastery_delta,
            "teacherSummary": (
                _teacher_summary_to_wire(teacher_summary)
                if teacher_summary
                else None
            ),
        })
        logger.info(
            "[live-session] pause done peer_ms=%.0f teacher_ms=%.0f total_ms=%.0f",
            peer_ms,
            teacher_ms,
            (time.monotonic() * 1000 - thinking_start_ms),
        )

        if teacher_summary and not self._interrupt_event.is_set():
            await self._stream_single_turn_to_client(teacher_summary, send=send)

        self._append_student_history_snapshot()
        for item in assessments:
            self.history.append(_assessment_to_history_item(item))
        if teacher_summary:
            self.history.append({
                "role": str(teacher_summary.get("role") or "teacher"),
                "displayName": str(teacher_summary.get("display_name") or "李老师"),
                "text": str(teacher_summary.get("text") or ""),
                "highlightStepIds": list(
                    teacher_summary.get("highlight_step_ids") or []
                ),
            })
        if len(self.history) > _HISTORY_KEEP_LAST:
            del self.history[: len(self.history) - _HISTORY_KEEP_LAST]

        self.round_index += 1
        self.last_status = status
        self.last_mastery_delta = mastery_delta
        self.is_thinking = False
        self._mark_transcript_round_consumed()

        await self._safe_send(send, {
            "type": EVT_ROUND_DONE,
            "sessionId": self.session_id,
            "status": status,
            "masteryDelta": mastery_delta,
            "allUnderstood": all_understood,
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
        if force:
            await self._send_error(send, "streaming_asr_not_configured")

    async def _handle_asr_result(
        self,
        result: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        if result.get("error"):
            logger.warning(
                "[live-session] ASR failed session=%s err=%s",
                self.session_id,
                result.get("error"),
            )
            await self._send_error(send, f"asr_failed:{result.get('error')}")
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

    async def _invoke_peer_assessments_streaming(
        self,
        *,
        peer_assessment_fn: Callable[..., dict[str, Any]],
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> dict[str, Any]:
        """三人并行评估；每名同伴完成即推送 item，不等到最慢的一个。"""
        del peer_assessment_fn  # live 主路径直连 assess_one_peer；submit 仍用 bulk API。
        from app.services.peer_assessment_agent import _PEER_ROLES, assess_one_peer

        steps_payload = [
            {
                "stepId": s.step_id,
                "latex": s.latex,
                "plainText": s.plain_text,
                "strokeCount": s.stroke_count,
            }
            for s in self.latest_steps
        ]
        speech = self._current_round_speech()
        allowed_step_ids = [s.step_id for s in self.latest_steps if s.step_id]
        loop = asyncio.get_event_loop()
        round_index = max(1, self.round_index + 1)
        history = list(self.history)

        async def _run_one(role: str) -> dict[str, Any]:
            return await loop.run_in_executor(
                None,
                lambda r=role: assess_one_peer(
                    role=r,
                    section_id=self.section_id,
                    question_id=self.question_id,
                    question_prompt=self.question_prompt,
                    student_speech_text=speech,
                    steps=steps_payload,
                    allowed_step_ids=allowed_step_ids,
                    round_index=round_index,
                    history=history,
                ),
            )

        tasks = {
            asyncio.create_task(_run_one(role)): role for role in _PEER_ROLES
        }
        by_role: dict[str, dict[str, Any]] = {}
        for finished in asyncio.as_completed(tasks.keys()):
            if self._interrupt_event.is_set():
                break
            item = await finished
            role = str(item.get("role") or "")
            by_role[role] = item
            await self._safe_send(send, {
                "type": EVT_PEER_ASSESSMENT_ITEM,
                "sessionId": self.session_id,
                "assessment": _assessment_to_wire(item),
            })

        assessments = [by_role[r] for r in _PEER_ROLES if r in by_role]
        if len(assessments) != len(_PEER_ROLES):
            raise RuntimeError("peer assessments incomplete")

        all_understood = all(a.get("understood") for a in assessments)
        status = "completed" if all_understood else "needs_explanation"
        mastery_delta = 1 if all_understood else 0
        return {
            "status": status,
            "mastery_delta": mastery_delta,
            "all_understood": all_understood,
            "assessments": assessments,
            "source": "llm",
        }

    async def _invoke_peer_assessments(
        self,
        peer_assessment_fn: Callable[..., dict[str, Any]],
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
        speech = self._current_round_speech()
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            None,
            lambda: peer_assessment_fn(
                section_id=self.section_id,
                question_id=self.question_id,
                question_prompt=self.question_prompt,
                student_speech_text=speech,
                steps=steps_payload,
                round_index=max(1, self.round_index + 1),
                history=list(self.history),
            ),
        )

    async def _invoke_teacher_summary(
        self,
        teacher_summary_fn: Callable[..., dict[str, Any]],
        *,
        peer_assessments: list[dict[str, Any]],
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
        speech = self._current_round_speech()
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            None,
            lambda: teacher_summary_fn(
                section_id=self.section_id,
                question_id=self.question_id,
                question_prompt=self.question_prompt,
                student_speech_text=speech,
                steps=steps_payload,
                round_index=max(1, self.round_index + 1),
                history=list(self.history),
                peer_assessments=peer_assessments,
            ),
        )

    async def _stream_single_turn_to_client(
        self,
        turn: dict[str, Any],
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        turn_id = str(turn.get("turn_id") or "summary_1")
        role = str(turn.get("role") or "teacher")
        display = str(turn.get("display_name") or "李老师")
        highlight = list(turn.get("highlight_step_ids") or [])
        text = str(turn.get("text") or "")
        await self._safe_send(send, {
            "type": EVT_AGENT_TURN_START,
            "sessionId": self.session_id,
            "turnId": turn_id,
            "role": role,
            "displayName": display,
            "highlightStepIds": highlight,
        })
        if text:
            await self._safe_send(send, {
                "type": EVT_AGENT_TURN_DELTA,
                "sessionId": self.session_id,
                "turnId": turn_id,
                "delta": text,
            })
            self._tts_role_by_turn[turn_id] = role
            self._maybe_dispatch_tts_sentence(
                turn_id=turn_id,
                delta=text,
                send=send,
            )
        self._flush_tts_remainder(turn_id=turn_id, send=send)
        await self._safe_send(send, {
            "type": EVT_AGENT_TURN_DONE,
            "sessionId": self.session_id,
            "turnId": turn_id,
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
        speech = self._current_round_speech()
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
        speech = self._current_round_speech()
        turns_by_id: dict[str, dict[str, Any]] = {}
        order: list[str] = []
        status = "needs_explanation"
        mastery_delta = 0

        # 第十二轮：原本写法 `for event in stream_agent_fn(...)` 是**同步 for 循环
        # 遍历 OpenAI SDK 的同步流**。OpenAI SDK 的 `next(stream)` 阻塞 asyncio
        # event loop，导致循环里的 `await self._safe_send(...)` 全部排队、无法真正
        # 把 ws frame 推到客户端 —— 现象就是「整段 LLM 跑完才一次性出现」。
        #
        # 修复：把同步 generator 跑在线程里，用 `asyncio.Queue` 把每个事件投回主
        # 协程；主协程 `await queue.get()` 拿一条立刻 `await self._safe_send(...)`，
        # event loop 再也不会被 OpenAI SDK 卡住。这样 deepseek 流式 chunk 一进来
        # 就能立刻翻成 ws delta 推给前端，前端气泡逐字滚动有了。
        loop = asyncio.get_event_loop()
        queue: asyncio.Queue = asyncio.Queue()
        sentinel = object()

        def _producer() -> None:
            try:
                for ev in stream_agent_fn(
                    section_id=self.section_id,
                    question_id=self.question_id,
                    question_prompt=self.question_prompt,
                    student_speech_text=speech,
                    steps=steps_payload,
                    round_index=max(1, self.round_index + 1),
                    history=list(self.history),
                ):
                    asyncio.run_coroutine_threadsafe(queue.put(ev), loop)
            except Exception as exc:  # noqa: BLE001
                asyncio.run_coroutine_threadsafe(
                    queue.put(("__producer_error__", exc)), loop
                )
            finally:
                asyncio.run_coroutine_threadsafe(queue.put(sentinel), loop)

        producer_future = loop.run_in_executor(None, _producer)

        while True:
            event = await queue.get()
            if event is sentinel:
                break
            if isinstance(event, tuple) and len(event) == 2 and event[0] == "__producer_error__":
                # producer 抛了 LectureAgentError 之类，等 future 完成（好释放
                # thread）再把异常向上抛 —— 调用方会兜底 send error 给客户端。
                try:
                    await producer_future
                finally:
                    raise event[1]
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
                # 流式 TTS：累积 delta 到完整一句就抠出来异步合成。
                role = turns_by_id[turn_id].get("role") or "teacher"
                self._tts_role_by_turn[turn_id] = role
                self._maybe_dispatch_tts_sentence(
                    turn_id=turn_id,
                    delta=delta,
                    send=send,
                )
            elif typ == "turn_done":
                turn_id = str(event.get("turnId") or (order[-1] if order else "turn_1"))
                # turn 结束，把缓冲里残留的不带句号的尾句也送去合成。
                self._flush_tts_remainder(turn_id=turn_id, send=send)
                await self._safe_send(send, {
                    "type": EVT_AGENT_TURN_DONE,
                    "sessionId": self.session_id,
                    "turnId": turn_id,
                })
            elif typ == "round_meta":
                status = str(event.get("status") or status)
                try:
                    mastery_delta = int(event.get("masteryDelta") or 0)
                except (TypeError, ValueError):
                    mastery_delta = 0
        turns = [turns_by_id[k] for k in order if k in turns_by_id]
        if len(turns) > 1:
            turns = turns[:1]
        return {
            "status": "needs_explanation",
            "mastery_delta": 0,
            "turns": turns,
            "source": "llm_stream",
        }

    async def _on_request_hint(
        self,
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        teacher_hint_fn: Callable[..., dict[str, Any]] | None,
    ) -> None:
        if teacher_hint_fn is None:
            await self._send_error(send, "teacher_hint_unavailable")
            return
        if self.is_thinking:
            await self._safe_send(send, {
                "type": EVT_WARNING,
                "sessionId": self.session_id,
                "message": "thinking_in_progress",
            })
            return

        self.is_thinking = True
        self._interrupt_event.clear()
        await self._safe_send(send, {
            "type": EVT_THINKING,
            "sessionId": self.session_id,
        })

        try:
            hint = await self._invoke_teacher_hint(teacher_hint_fn)
        except Exception as e:  # noqa: BLE001
            logger.exception("[live-session] teacher_hint 失败：%s", e)
            await self._send_error(send, f"teacher_hint_failed:{e}")
            self.is_thinking = False
            return

        turn_id = str(hint.get("turn_id") or "hint_1")
        role = str(hint.get("role") or "teacher")
        display = str(hint.get("display_name") or "李老师")
        highlight = list(hint.get("highlight_step_ids") or [])
        text = str(hint.get("text") or "")

        await self._safe_send(send, {
            "type": EVT_AGENT_TURN_START,
            "sessionId": self.session_id,
            "turnId": turn_id,
            "role": role,
            "displayName": display,
            "highlightStepIds": highlight,
        })
        if text:
            await self._safe_send(send, {
                "type": EVT_AGENT_TURN_DELTA,
                "sessionId": self.session_id,
                "turnId": turn_id,
                "delta": text,
            })
            self._tts_role_by_turn[turn_id] = role
            self._maybe_dispatch_tts_sentence(
                turn_id=turn_id,
                delta=text,
                send=send,
            )
        self._flush_tts_remainder(turn_id=turn_id, send=send)
        await self._safe_send(send, {
            "type": EVT_AGENT_TURN_DONE,
            "sessionId": self.session_id,
            "turnId": turn_id,
        })

        self.history.append({
            "role": role,
            "displayName": display,
            "text": text,
            "highlightStepIds": highlight,
        })
        if len(self.history) > _HISTORY_KEEP_LAST:
            del self.history[: len(self.history) - _HISTORY_KEEP_LAST]

        self.is_thinking = False
        await self._safe_send(send, {
            "type": EVT_LISTENING,
            "sessionId": self.session_id,
        })

    async def _invoke_teacher_hint(
        self,
        teacher_hint_fn: Callable[..., dict[str, Any]],
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
        speech = self._current_round_speech()
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(
            None,
            lambda: teacher_hint_fn(
                section_id=self.section_id,
                question_id=self.question_id,
                question_prompt=self.question_prompt,
                student_speech_text=speech,
                steps=steps_payload,
                round_index=max(1, self.round_index + 1),
                history=list(self.history),
            ),
        )

    # ============================================================== #
    # 流式 TTS（第十二轮第三轮）
    # ============================================================== #

    # 中文句子切分：句号 / 问号 / 感叹号 / 中文分号 都视为句末（注意 LaTeX 里的
    # `\.` 不该被切；这里只匹配单字符标点，避开反斜杠转义）。
    _SENTENCE_END_PUNCT: tuple[str, ...] = ("。", "！", "？", "!", "?", "；", ";")

    # 一句太长时强制截断（给火山的单次合成上限做预防），按字符数。
    _SENTENCE_MAX_CHARS = 80

    def _maybe_dispatch_tts_sentence(
        self,
        *,
        turn_id: str,
        delta: str,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        """累积一段 delta；遇到完整句子或缓冲超长时切出去丢给后台流式 TTS。"""
        if not delta:
            return
        buf = self._tts_buffer_by_turn.get(turn_id, "") + delta
        # 反复扫描句末标点，把每个完整句切出去。
        while True:
            idx = -1
            for p in self._SENTENCE_END_PUNCT:
                pos = buf.find(p)
                if pos >= 0 and (idx < 0 or pos < idx):
                    idx = pos
            if idx < 0:
                # 没有句末标点；如果累积太长也强切，避免一句话憋到 turn_done 才合成。
                if len(buf) >= self._SENTENCE_MAX_CHARS:
                    sentence = buf[: self._SENTENCE_MAX_CHARS]
                    buf = buf[self._SENTENCE_MAX_CHARS :]
                    self._launch_tts_task(turn_id, sentence, send)
                    continue
                break
            sentence = buf[: idx + 1]
            buf = buf[idx + 1 :]
            self._launch_tts_task(turn_id, sentence, send)
        self._tts_buffer_by_turn[turn_id] = buf

    def _flush_tts_remainder(
        self,
        *,
        turn_id: str,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        rest = self._tts_buffer_by_turn.pop(turn_id, "").strip()
        if rest:
            self._launch_tts_task(turn_id, rest, send)

    def _launch_tts_task(
        self,
        turn_id: str,
        sentence: str,
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        from app.services.tts_text import plain_text_for_tts

        sentence = plain_text_for_tts(sentence.strip())
        if not sentence:
            return
        seq = self._tts_seq_by_turn.get(turn_id, 0)
        self._tts_seq_by_turn[turn_id] = seq + 1
        role = self._tts_role_by_turn.get(turn_id, "teacher")

        async def _run() -> None:
            await self._stream_tts_for_sentence(
                send=send,
                turn_id=turn_id,
                seq=seq,
                role=role,
                sentence=sentence,
            )

        prev = self._tts_tail_by_turn.get(turn_id)

        async def _chained() -> None:
            if prev is not None and not prev.done():
                try:
                    await prev
                except Exception:  # noqa: BLE001
                    pass
            await _run()

        task = asyncio.create_task(_chained())
        self._tts_tail_by_turn[turn_id] = task

    async def _stream_tts_for_sentence(
        self,
        *,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        turn_id: str,
        seq: int,
        role: str,
        sentence: str,
    ) -> None:
        from app.config import Config
        from app.services import volc_tts

        speaker = Config.SPEAKER_BY_ROLE.get(role, Config.VOLC_DEFAULT_SPEAKER)

        loop = asyncio.get_event_loop()
        queue: asyncio.Queue = asyncio.Queue()
        sentinel = object()

        def _producer() -> None:
            try:
                for audio_bytes in volc_tts.synthesize_stream(sentence, speaker):
                    asyncio.run_coroutine_threadsafe(queue.put(audio_bytes), loop)
            except Exception as exc:  # noqa: BLE001
                asyncio.run_coroutine_threadsafe(
                    queue.put(("__error__", exc)), loop
                )
            finally:
                asyncio.run_coroutine_threadsafe(queue.put(sentinel), loop)

        loop.run_in_executor(None, _producer)

        chunk_index = 0
        while True:
            item = await queue.get()
            if item is sentinel:
                break
            if isinstance(item, tuple) and len(item) == 2 and item[0] == "__error__":
                logger.warning(
                    "[live-session] tts stream failed turn=%s seq=%d err=%s",
                    turn_id,
                    seq,
                    item[1],
                )
                # 给前端一条 warning，让 UI 可以选择性提示但不阻塞气泡。
                await self._safe_send(send, {
                    "type": EVT_WARNING,
                    "sessionId": self.session_id,
                    "message": f"tts_failed:{turn_id}:{seq}",
                })
                return
            if self._interrupt_event.is_set():
                # 学生打断 → 把后续 mp3 chunk 全吞掉。
                continue
            chunk_index += 1
            await self._safe_send(send, {
                "type": EVT_AGENT_TTS_CHUNK,
                "sessionId": self.session_id,
                "turnId": turn_id,
                "role": role,
                "seq": seq,
                "chunkIndex": chunk_index,
                "audioBase64": base64.b64encode(item).decode("ascii"),
                "format": "mp3",
                # done=True 由调用方在 last chunk 标记 —— 这里我们用前端能识别的
                # 「chunkIndex 不再增加」语义；后端无法判断「下一段是否还有」，
                # 简单做法：每段都不带 done，前端按 turn 的 agent_turn_done 来
                # 判断"本 turn 不会再有 tts chunk"。
            })

    def _append_student_history_snapshot(self) -> None:
        speech = self._current_round_speech()
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

    async def _send_error(
        self,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        message: str,
    ) -> None:
        await self._safe_send(send, {
            "type": EVT_ERROR,
            "sessionId": self.session_id,
            "message": message,
        })


def _assessment_to_wire(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "role": str(item.get("role") or "xiaoming"),
        "displayName": str(item.get("display_name") or ""),
        "understood": bool(item.get("understood")),
        "reason": str(item.get("reason") or ""),
        "highlightStepIds": list(item.get("highlight_step_ids") or []),
    }


def _teacher_summary_to_wire(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "turnId": str(item.get("turn_id") or "summary_1"),
        "role": str(item.get("role") or "teacher"),
        "displayName": str(item.get("display_name") or "李老师"),
        "text": str(item.get("text") or ""),
        "highlightStepIds": list(item.get("highlight_step_ids") or []),
    }


def _assessment_to_history_item(item: dict[str, Any]) -> dict[str, Any]:
    understood = bool(item.get("understood"))
    reason = str(item.get("reason") or "").strip()
    display = str(item.get("display_name") or "")
    text = f"（听懂了）{reason}" if understood else reason
    return {
        "role": str(item.get("role") or "xiaoming"),
        "displayName": display,
        "text": text,
        "highlightStepIds": list(item.get("highlight_step_ids") or []),
    }


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
