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

import logging
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.services.lecture_agent import generate_lecture_turns
from app.services.live_lecture_session import (
    EVT_ERROR,
    LiveLectureSession,
)
from app.services.volc_asr import recognize as volc_recognize

logger = logging.getLogger(__name__)


router = APIRouter(tags=["LectureLive"])


@router.websocket("/lecture/live")
async def lecture_live(websocket: WebSocket) -> None:
    await websocket.accept()
    session = LiveLectureSession()

    async def send(payload: dict[str, Any]) -> None:
        await websocket.send_json(payload)

    try:
        while True:
            try:
                event = await websocket.receive_json()
            except WebSocketDisconnect:
                logger.info(
                    "[lecture-live] websocket disconnected session=%s",
                    session.session_id or "(no session)",
                )
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
                    lecture_agent_fn=generate_lecture_turns,
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
    except Exception as e:  # noqa: BLE001
        logger.exception("[lecture-live] unexpected loop exit: %s", e)
        try:
            await websocket.close()
        except Exception:  # noqa: BLE001
            pass
