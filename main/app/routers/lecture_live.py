"""WebSocket /lecture/live —— 第九轮实时讲题主入口。

设计要点：

- 一条 WS 连接 ↔ 一个 ``LiveLectureSession``；FastAPI 自动给每条连接起一个
  独立 asyncio task，因此 session 内部所有 handler 不会被并发触发。
- 协议见 ``services.live_lecture_session`` 顶部注释 / brief 第 6 节。
- 失败语义：客户端打错任意一条事件都只 warning，不踢连接；只有学生
  显式 ``session_end`` 或 WS 断开才真正退出。
- 鉴权：本轮仍**不**接入 ``require_user``，与 ``/lecture/submit`` 口径一致 ——
  V1 客户端尚无登录态，演示链路不能被 401 拦截。
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.db import (
    LearningProgress,
    LectureSessionRecord,
    SessionLocal,
    User,
    dump_json,
    ensure_student_profile,
)
from app.middleware.auth import decode_token
from app.services.peer_assessment_agent import generate_peer_assessments
from app.services.teacher_agent import generate_teacher_hint, generate_teacher_summary
from app.services.live_lecture_session import (
    EVT_ERROR,
    LiveLectureSession,
)
from app.services.volc_asr import recognize as volc_recognize

logger = logging.getLogger(__name__)


router = APIRouter(tags=["LectureLive"])
_HEARTBEAT_SECONDS = 8.0


def _extract_user_from_ws(websocket: WebSocket) -> User | None:
    """从 WS 握手携带的 token query / header 里解析登录用户。

    支持两种传递方式：
    - `?token=<jwt>` query 参数（移动端 Web/Mobile 都好传）；
    - `Authorization: Bearer <jwt>` header（标准 HTTP 头）。

    任意解析失败都返回 None，匿名会话仍然可以使用 `/lecture/live`，与
    第九轮 demo 链路完全兼容。
    """

    token = websocket.query_params.get("token") if websocket.query_params else None
    if not token:
        auth_header = websocket.headers.get("authorization") or ""
        if auth_header.lower().startswith("bearer "):
            token = auth_header[7:].strip()
    if not token:
        return None
    payload = decode_token(token)
    if not payload:
        return None
    username = payload.get("sub")
    if not username:
        return None
    db = SessionLocal()
    try:
        return db.query(User).filter(User.username == username).first()
    finally:
        db.close()


@router.websocket("/lecture/live")
async def lecture_live(websocket: WebSocket) -> None:
    await websocket.accept()
    user = _extract_user_from_ws(websocket)
    session = LiveLectureSession()
    send_lock = asyncio.Lock()

    async def send(payload: dict[str, Any]) -> None:
        async with send_lock:
            await websocket.send_json(payload)

    async def heartbeat() -> None:
        while True:
            await asyncio.sleep(_HEARTBEAT_SECONDS)
            try:
                await send({
                    "type": "warning",
                    "sessionId": session.session_id,
                    "message": "heartbeat",
                })
            except Exception:  # noqa: BLE001
                return

    heartbeat_task = asyncio.create_task(heartbeat())

    try:
        while True:
            try:
                event = await websocket.receive_json()
            except WebSocketDisconnect:
                logger.info(
                    "[lecture-live] websocket disconnected session=%s",
                    session.session_id or "(no session)",
                )
                _persist_live_session_if_needed(user, session)
                return
            except Exception as e:  # noqa: BLE001
                # 非 JSON / 解码失败：通知客户端但不断开。
                logger.warning("[lecture-live] receive failed: %s", e)
                try:
                    await send({
                        "type": EVT_ERROR,
                        "sessionId": session.session_id,
                        "message": "invalid_json",
                    })
                except Exception:  # noqa: BLE001
                    _persist_live_session_if_needed(user, session)
                    return
                continue

            if not isinstance(event, dict):
                await send({
                    "type": EVT_ERROR,
                    "sessionId": session.session_id,
                    "message": "event_must_be_object",
                })
                continue

            try:
                keep = await session.handle_event(
                    event,
                    send=send,
                    recognize_fn=volc_recognize,
                    peer_assessment_fn=generate_peer_assessments,
                    teacher_summary_fn=generate_teacher_summary,
                    teacher_hint_fn=generate_teacher_hint,
                )
            except Exception as e:  # noqa: BLE001
                logger.exception("[lecture-live] handle_event 异常：%s", e)
                try:
                    await send({
                        "type": EVT_ERROR,
                        "sessionId": session.session_id,
                        "message": "session_handler_error",
                    })
                except Exception:  # noqa: BLE001
                    return
                continue

            if not keep:
                logger.info(
                    "[lecture-live] session_end requested session=%s",
                    session.session_id,
                )
                _persist_live_session_if_needed(user, session)
                try:
                    await websocket.close()
                except Exception:  # noqa: BLE001
                    pass
                return
    except WebSocketDisconnect:
        logger.info(
            "[lecture-live] websocket disconnected session=%s",
            session.session_id or "(no session)",
        )
        _persist_live_session_if_needed(user, session)
    except Exception as e:  # noqa: BLE001
        logger.exception("[lecture-live] unexpected loop exit: %s", e)
        _persist_live_session_if_needed(user, session)
        try:
            await websocket.close()
        except Exception:  # noqa: BLE001
            pass
    finally:
        heartbeat_task.cancel()
        try:
            await heartbeat_task
        except asyncio.CancelledError:
            pass


def _persist_live_session_if_needed(
    user: User | None,
    session: LiveLectureSession,
) -> None:
    """实时会话结束时，把会话快照写入 LectureSessionRecord 并按需更新进度。

    仅在 (1) 携带了 token (2) session 已经 session_start 过且 round_count > 0
    时落库，避免匿名 / 空会话污染数据库。
    """

    if user is None:
        return
    if not session.session_id or session.round_index <= 0:
        return
    db = SessionLocal()
    try:
        profile = ensure_student_profile(db, user)
        steps_payload = [
            {
                "stepId": s.step_id,
                "latex": s.latex,
                "plainText": s.plain_text,
                "strokeCount": s.stroke_count,
            }
            for s in session.latest_steps
        ]
        # 把 history 里的 AI turns 抠出来，避免和 student 历史项混杂。
        turns_payload = [
            h
            for h in session.history
            if str(h.get("role") or "")
            in ("xiaoming", "daxiong", "monitor", "teacher")
        ]
        transcript = " ".join(session.transcript_segments).strip()

        row = LectureSessionRecord(
            student_id=profile.id,
            session_id=session.session_id,
            section_id=session.section_id or "",
            question_id=session.question_id or "",
            question_prompt=session.question_prompt or "",
            status=session.last_status or "needs_explanation",
            transcript_text=transcript,
            steps_json=dump_json(steps_payload),
            turns_json=dump_json(turns_payload),
            mastery_delta=int(session.last_mastery_delta or 0),
            round_count=session.round_index,
            started_at=datetime.utcnow(),
            completed_at=datetime.utcnow(),
        )
        db.add(row)

        progress_delta = int(session.last_mastery_delta or 0)
        should_update_progress = (
            (session.last_status or "") == "completed"
            and progress_delta > 0
            and bool(session.section_id)
        )
        if should_update_progress:
            progress = (
                db.query(LearningProgress)
                .filter(
                    LearningProgress.student_id == profile.id,
                    LearningProgress.section_id == session.section_id,
                )
                .first()
            )
            score_gain = progress_delta * 8
            if progress is None:
                progress = LearningProgress(
                    student_id=profile.id,
                    section_id=session.section_id,
                    completed_rounds=1,
                    mastery_score=min(100, score_gain),
                    last_practiced_at=datetime.utcnow(),
                    last_summary=transcript[:200],
                )
                db.add(progress)
            else:
                progress.completed_rounds = (
                    int(progress.completed_rounds or 0) + 1
                )
                progress.mastery_score = min(
                    100, int(progress.mastery_score or 0) + score_gain
                )
                progress.last_practiced_at = datetime.utcnow()
                if transcript:
                    progress.last_summary = transcript[:200]

        if should_update_progress and session.question_id:
            from app.services.assignment_service import mark_assignments_completed

            summary_text = turns_payload[-1].get("text", "") if turns_payload else transcript[:200]
            mark_assignments_completed(
                db,
                student_id=profile.id,
                section_id=session.section_id or "",
                question_id=session.question_id or "",
                summary=summary_text,
                mastery_delta=progress_delta,
                round_count=session.round_index,
            )

        db.commit()
    except Exception as e:  # noqa: BLE001
        logger.warning(
            "[lecture-live] persist session failed user=%s err=%s",
            user.username,
            e,
        )
        try:
            db.rollback()
        except Exception:  # noqa: BLE001
            pass
    finally:
        db.close()
