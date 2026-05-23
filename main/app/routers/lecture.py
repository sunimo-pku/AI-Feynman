"""讲题 / 多 Agent 追问路由。

- 第二轮：曾返回固定 JSON Mock。
- 第三轮：交由 `services.lecture_agent.generate_lecture_turns(...)`
  调用真实 LLM 生成强结构化多 Agent 追问；LLM 不可用 / 解析失败 / 校验失败时
  直接返回 502，让调用方看到真实故障。
- 第四轮：请求体新增 `studentSpeechText` 与 `steps[*].plainText / latex` 三个学生语义字段。
- 第五轮（当前）：请求体新增可选 `roundIndex` 与 `history` 两个字段，让后端能感知
  「学生这次到底是在回答上一轮 AI 的哪个问题」，并据此判定是继续追问还是 `completed`。
  旧请求体不传这两个字段仍能通过：`roundIndex` 默认 1、`history` 默认 []。

设计要点：

- 路由前缀使用业务语义 `/lecture`，避免与 `/chat` 通用对话端点混淆。
- 强 Schema：Pydantic v2 模型，所有字段显式声明，前端就能直接 from_json。
- 不引入 `require_user`：当前 Flutter 客户端尚未做登录态，演示链路不应被 401 拦腰截断。
- 错误：参数缺失走 422（由 FastAPI / Pydantic 自动产生）；
       空步骤数组走 400 —— 经 HTTPException 抛出，
       不走 `return {"error": ...}` 假 200。
- LLM 错误必须显式暴露：失败返回 502，禁止用 Mock 文案伪装成功。
- `history` 我们刻意**不**做严格枚举校验：陌生 role 字符串会被 `lecture_agent`
  在 prompt 拼装阶段静默忽略，避免某天前端打错 role 名直接让整次 /submit 走
  422 破坏 Demo 体感。
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureSessionRecord,
    User,
    dump_json,
    ensure_student_profile,
    get_db,
)
from app.middleware.auth import get_current_user
from app.services.lecture_agent import LectureAgentError
from app.services.peer_assessment_agent import generate_peer_assessments
from app.services.teacher_agent import generate_teacher_hint, generate_teacher_summary

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/lecture", tags=["Lecture"])


# ---------------------------------------------------------------------------
# 请求模型
# ---------------------------------------------------------------------------


class BoundingBox(BaseModel):
    """前端预留给步骤高亮定位的包围盒；本轮仅占位，未做后端校验。"""

    x: float = Field(..., ge=0)
    y: float = Field(..., ge=0)
    width: float = Field(..., gt=0)
    height: float = Field(..., gt=0)


class LectureStep(BaseModel):
    step_id: str = Field(..., alias="stepId", min_length=1, max_length=64)
    latex: str = ""
    plain_text: str = Field("", alias="plainText")
    stroke_count: int = Field(0, alias="strokeCount", ge=0)
    bounding_box: BoundingBox | None = Field(None, alias="boundingBox")

    model_config = {
        "populate_by_name": True,
    }


class LectureHistoryItem(BaseModel):
    """单条多轮上下文历史项。

    把当前题目内的「学生上一轮说了什么 / AI 上一轮追问了什么」一并随
    `/lecture/submit` 上传，让后端 LLM 能延续上下文，而不是重复追问同一个问题。

    字段约束故意宽松：
      * `role` 用 str 而不是枚举，遇到陌生 role 由 service 静默忽略，避免打错字段
        名直接让整次 /submit 走 422。
      * `text` 上限 1000 字符够长（一条 LLM 追问 ≤180 中文字符 + 富格式，留余量）。
      * `display_name` 选填，为空时由 service 按 role 自动补全。
    """

    role: str = Field("", min_length=0, max_length=32)
    display_name: str = Field("", alias="displayName", max_length=32)
    text: str = Field("", max_length=1000)
    highlight_step_ids: list[str] = Field(
        default_factory=list,
        alias="highlightStepIds",
    )

    model_config = {
        "populate_by_name": True,
    }


class LectureSubmitRequest(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_id: str = Field(..., alias="questionId", min_length=1, max_length=64)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    student_speech_text: str = Field("", alias="studentSpeechText", max_length=4000)
    steps: list[LectureStep] = Field(default_factory=list)

    # 保持旧 Flutter 客户端不传这两个字段也能通过。
    # `round_index` 从 1 开始，第一次提交是第 1 轮；第二次提交（学生在回答 AI 追问）
    # 应当是 2，依此类推。这个语义对追问生成很关键 ——「回答上一轮追问」与
    # 「重新讲一遍」要求 LLM 输出风格完全不同。
    round_index: int = Field(1, alias="roundIndex", ge=1, le=20)
    history: list[LectureHistoryItem] = Field(default_factory=list)

    model_config = {
        "populate_by_name": True,
    }


# ---------------------------------------------------------------------------
# 响应模型
# ---------------------------------------------------------------------------


AgentRole = Literal["xiaoming", "daxiong", "monitor", "teacher", "system"]


class AgentTurnOut(BaseModel):
    turn_id: str = Field(..., serialization_alias="turnId")
    role: AgentRole
    display_name: str = Field(..., serialization_alias="displayName")
    text: str
    method_summary: str = Field("", serialization_alias="methodSummary")
    highlight_step_ids: list[str] = Field(
        default_factory=list,
        serialization_alias="highlightStepIds",
    )

    model_config = {
        "populate_by_name": True,
    }


class PeerAssessmentOut(BaseModel):
    role: Literal["xiaoming", "daxiong", "monitor"]
    display_name: str = Field(..., serialization_alias="displayName")
    understood: bool
    reason: str
    highlight_step_ids: list[str] = Field(
        default_factory=list,
        serialization_alias="highlightStepIds",
    )

    model_config = {
        "populate_by_name": True,
    }


class LectureSubmitResponse(BaseModel):
    question_id: str = Field(..., serialization_alias="questionId")
    section_id: str = Field(..., serialization_alias="sectionId")
    status: Literal["needs_explanation", "completed"] = "needs_explanation"
    mastery_delta: int = Field(0, serialization_alias="masteryDelta")
    all_understood: bool = Field(False, serialization_alias="allUnderstood")
    assessments: list[PeerAssessmentOut] = Field(default_factory=list)
    teacher_summary: AgentTurnOut | None = Field(None, serialization_alias="teacherSummary")
    turns: list[AgentTurnOut] = Field(default_factory=list)

    model_config = {
        "populate_by_name": True,
    }


class LectureHintResponse(BaseModel):
    turn: AgentTurnOut

    model_config = {
        "populate_by_name": True,
    }


# ---------------------------------------------------------------------------
# 响应组装
# ---------------------------------------------------------------------------


def _assessments_to_turns_payload(
    assessments: list[dict[str, Any]],
    teacher_summary: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    """把评估结果转成 turns 快照，供落库与旧字段兼容。"""
    turns: list[dict[str, Any]] = []
    for idx, item in enumerate(assessments, start=1):
        if item.get("understood"):
            continue
        turns.append(
            {
                "turn_id": f"assess_{item.get('role', idx)}",
                "role": item.get("role", "xiaoming"),
                "display_name": item.get("display_name", ""),
                "text": item.get("reason", ""),
                "highlight_step_ids": list(item.get("highlight_step_ids") or []),
            }
        )
    if teacher_summary:
        turns.append(teacher_summary)
    return turns


def _build_submit_response(
    *,
    req: LectureSubmitRequest,
    result: dict[str, Any],
    teacher_summary: dict[str, Any] | None,
) -> LectureSubmitResponse:
    assessments_out = [
        PeerAssessmentOut(
            role=a["role"],
            display_name=a["display_name"],
            understood=bool(a["understood"]),
            reason=str(a.get("reason") or ""),
            highlight_step_ids=list(a.get("highlight_step_ids") or []),
        )
        for a in result.get("assessments", [])
    ]
    teacher_out: AgentTurnOut | None = None
    if teacher_summary:
        teacher_out = AgentTurnOut(
            turn_id=teacher_summary["turn_id"],
            role=teacher_summary["role"],
            display_name=teacher_summary["display_name"],
            text=teacher_summary["text"],
            method_summary=str(teacher_summary.get("method_summary") or ""),
            highlight_step_ids=list(teacher_summary.get("highlight_step_ids") or []),
        )
    turns_payload = _assessments_to_turns_payload(
        result.get("assessments", []),
        teacher_summary,
    )
    turns = [
        AgentTurnOut(
            turn_id=t["turn_id"],
            role=t["role"],
            display_name=t["display_name"],
            text=t["text"],
            highlight_step_ids=t.get("highlight_step_ids", []),
        )
        for t in turns_payload
    ]
    return LectureSubmitResponse(
        question_id=req.question_id,
        section_id=req.section_id,
        status=result.get("status", "needs_explanation"),
        mastery_delta=int(result.get("mastery_delta", 0) or 0),
        all_understood=bool(result.get("all_understood")),
        assessments=assessments_out,
        teacher_summary=teacher_out,
        turns=turns,
    )


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------


@router.post(
    "/submit",
    response_model=LectureSubmitResponse,
    response_model_by_alias=True,
    summary="提交学生讲解 → LLM 生成多 Agent 追问（失败返回 502）",
)
async def submit_lecture(
    req: LectureSubmitRequest,
    user: User | None = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> LectureSubmitResponse:
    if not req.steps:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="At least one handwriting step is required before submitting.",
        )

    # 把请求里的步骤转成纯 dict 喂给 service —— 让 service 不再依赖路由层的
    # Pydantic 模型，未来抽到单独的进程也能复用。
    steps_payload = [
        {
            "stepId": s.step_id,
            "latex": s.latex,
            "plainText": s.plain_text,
            "strokeCount": s.stroke_count,
        }
        for s in req.steps
    ]

    # 历史也转成 dict，service 内部按 role 字符串再做一次白名单兼容。
    history_payload = [
        {
            "role": h.role,
            "displayName": h.display_name,
            "text": h.text,
            "highlightStepIds": list(h.highlight_step_ids),
        }
        for h in req.history
    ]

    try:
        result = generate_peer_assessments(
            section_id=req.section_id,
            question_id=req.question_id,
            question_prompt=req.question_prompt,
            student_speech_text=req.student_speech_text,
            steps=steps_payload,
            round_index=req.round_index,
            history=history_payload,
        )
        teacher_summary: dict[str, Any] | None = None
        if result.get("all_understood"):
            teacher_summary = generate_teacher_summary(
                section_id=req.section_id,
                question_id=req.question_id,
                question_prompt=req.question_prompt,
                student_speech_text=req.student_speech_text,
                steps=steps_payload,
                round_index=req.round_index,
                history=history_payload,
                peer_assessments=result.get("assessments"),
            )
    except LectureAgentError as e:
        logger.exception(
            "[lecture] /submit peer assessment failed section=%s question=%s round=%d",
            req.section_id,
            req.question_id,
            req.round_index,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Peer assessment failed: {e}",
        ) from e

    turns_payload = _assessments_to_turns_payload(
        result.get("assessments", []),
        teacher_summary,
    )

    logger.info(
        "[lecture] /submit section=%s question=%s round=%d steps=%d "
        "history=%d source=%s status=%s all_understood=%s assessments=%d",
        req.section_id,
        req.question_id,
        req.round_index,
        len(req.steps),
        len(req.history),
        result.get("source"),
        result.get("status"),
        result.get("all_understood"),
        len(result.get("assessments", [])),
    )

    if user is not None:
        try:
            _persist_lecture_submission(
                db=db,
                user=user,
                req=req,
                steps_payload=steps_payload,
                turns_payload=turns_payload,
                status_value=result.get("status", "needs_explanation"),
                mastery_delta=int(result.get("mastery_delta", 0) or 0),
            )
        except Exception as e:  # noqa: BLE001
            logger.warning(
                "[lecture] persist submission failed user=%s err=%s",
                user.username,
                e,
            )

    return _build_submit_response(
        req=req,
        result=result,
        teacher_summary=teacher_summary,
    )


@router.post(
    "/hint",
    response_model=LectureHintResponse,
    response_model_by_alias=True,
    summary="学生主动请求李老师提示（独立 Agent，失败返回 502）",
)
async def request_teacher_hint(
    req: LectureSubmitRequest,
    user: User | None = Depends(get_current_user),
) -> LectureHintResponse:
    steps_payload = [
        {
            "stepId": s.step_id,
            "latex": s.latex,
            "plainText": s.plain_text,
            "strokeCount": s.stroke_count,
        }
        for s in req.steps
    ]
    history_payload = [
        {
            "role": h.role,
            "displayName": h.display_name,
            "text": h.text,
            "highlightStepIds": list(h.highlight_step_ids),
        }
        for h in req.history
    ]

    try:
        result = generate_teacher_hint(
            section_id=req.section_id,
            question_id=req.question_id,
            question_prompt=req.question_prompt,
            student_speech_text=req.student_speech_text,
            steps=steps_payload,
            round_index=req.round_index,
            history=history_payload,
        )
    except LectureAgentError as e:
        logger.exception(
            "[lecture] /hint agent failed section=%s question=%s round=%d",
            req.section_id,
            req.question_id,
            req.round_index,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Teacher hint failed: {e}",
        ) from e

    logger.info(
        "[lecture] /hint section=%s question=%s round=%d user=%s",
        req.section_id,
        req.question_id,
        req.round_index,
        user.username if user else "anonymous",
    )

    turn = AgentTurnOut(
        turn_id=result["turn_id"],
        role=result["role"],
        display_name=result["display_name"],
        text=result["text"],
        highlight_step_ids=result.get("highlight_step_ids", []),
    )
    return LectureHintResponse(turn=turn)


# ---------------------------------------------------------------------------
# 持久化辅助（仅在带 Bearer 时调用）
# ---------------------------------------------------------------------------


def _persist_lecture_submission(
    *,
    db: Session,
    user: User,
    req: LectureSubmitRequest,
    steps_payload: list[dict],
    turns_payload: list[dict],
    status_value: str,
    mastery_delta: int,
) -> None:
    """把单次 /lecture/submit 持久化为 LectureSessionRecord，并在 completed
    时同步更新 LearningProgress。

    SessionRecord 的 `session_id` 用 `questionId-round` 作为伪 id（非
    真实 WS 会话），便于和实时讲题路径区分；同一题多轮提交时累加 round_count。
    """

    profile = ensure_student_profile(db, user)

    pseudo_session_id = f"submit-{req.question_id}-{req.round_index}"

    # 找一条同题同 session_id 的旧记录，避免重复同步同一轮；找不到则新建。
    existing = (
        db.query(LectureSessionRecord)
        .filter(
            LectureSessionRecord.student_id == profile.id,
            LectureSessionRecord.session_id == pseudo_session_id,
        )
        .first()
    )
    if existing is None:
        existing = LectureSessionRecord(
            student_id=profile.id,
            session_id=pseudo_session_id,
            section_id=req.section_id,
            question_id=req.question_id,
            question_prompt=req.question_prompt,
            status=status_value,
            transcript_text=req.student_speech_text,
            steps_json=dump_json(steps_payload),
            turns_json=dump_json(turns_payload),
            mastery_delta=mastery_delta,
            round_count=max(1, int(req.round_index or 1)),
            started_at=datetime.utcnow(),
            completed_at=datetime.utcnow() if status_value == "completed" else None,
        )
        db.add(existing)
    else:
        existing.status = status_value
        existing.transcript_text = req.student_speech_text
        existing.steps_json = dump_json(steps_payload)
        existing.turns_json = dump_json(turns_payload)
        existing.mastery_delta = mastery_delta
        existing.round_count = max(existing.round_count or 1, int(req.round_index or 1))
        if status_value == "completed":
            existing.completed_at = datetime.utcnow()

    # completed → 更新 LearningProgress：累加一轮 + 加分（与前端
    # `SectionProgress.applyCompleted` 同口径，避免登录后家长端看到的
    # 分数与学生端本地分数差太多）。
    if status_value == "completed":
        progress = (
            db.query(LearningProgress)
            .filter(
                LearningProgress.student_id == profile.id,
                LearningProgress.section_id == req.section_id,
            )
            .first()
        )
        gain = max(8, mastery_delta * 10)
        if progress is None:
            progress = LearningProgress(
                student_id=profile.id,
                section_id=req.section_id,
                completed_rounds=1,
                mastery_score=min(100, gain),
                last_practiced_at=datetime.utcnow(),
                last_summary=(
                    turns_payload[-1].get("text", "") if turns_payload else ""
                ),
            )
            db.add(progress)
        else:
            progress.completed_rounds = int(progress.completed_rounds or 0) + 1
            progress.mastery_score = min(
                100, int(progress.mastery_score or 0) + gain
            )
            progress.last_practiced_at = datetime.utcnow()
            if turns_payload:
                progress.last_summary = turns_payload[-1].get("text", "") or (
                    progress.last_summary or ""
                )

        existing.mastery_after = progress.mastery_score

        from app.services.assignment_service import mark_assignments_completed

        summary_text = turns_payload[-1].get("text", "") if turns_payload else ""
        mark_assignments_completed(
            db,
            student_id=profile.id,
            section_id=req.section_id,
            question_id=req.question_id,
            summary=summary_text,
            mastery_delta=mastery_delta,
            round_count=int(req.round_index or 1),
        )

    db.commit()
