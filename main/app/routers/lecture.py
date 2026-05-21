"""讲题 / 多 Agent 追问路由。

- 第二轮：返回固定 JSON Mock。
- 第三轮：交由 `services.lecture_agent.generate_lecture_turns(...)`
  调用真实 LLM 生成强结构化多 Agent 追问；LLM 不可用 / 解析失败 / 校验失败时
  自动回退到第二轮的固定 Mock，保证 Demo 链路不中断。
- 第四轮：请求体新增 `studentSpeechText` 与 `steps[*].plainText / latex` 三个学生语义字段。
- 第五轮（当前）：请求体新增可选 `roundIndex` 与 `history` 两个字段，让后端能感知
  「学生这次到底是在回答上一轮 AI 的哪个问题」，并据此判定是继续追问还是 `completed`。
  旧请求体不传这两个字段仍能通过：`roundIndex` 默认 1、`history` 默认 []。

设计要点：

- 路由前缀使用业务语义 `/lecture`，避免与 `/chat` 通用对话端点混淆。
- 强 Schema：Pydantic v2 模型，所有字段显式声明，前端就能直接 from_json。
- 不引入 `require_user`：当前 Flutter 客户端尚未做登录态，演示链路不应被 401 拦腰截断。
- 错误：参数缺失走 422（由 FastAPI / Pydantic 自动产生）；
       未知章节走 404；空步骤数组走 400 —— 全部经 HTTPException 抛出，
       不走 `return {"error": ...}` 假 200。
- LLM 错误**不**抛 HTTPException：会让前端看到红色错误条，破坏 Demo；
  统一由 service 回落 fallback，路由层只看 `source` 字段写日志。
- `history` 我们刻意**不**做严格枚举校验：陌生 role 字符串会被 `lecture_agent`
  在 prompt 拼装阶段静默忽略，避免某天前端打错 role 名直接让整次 /submit 走
  422 破坏 Demo 体感。
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Literal

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
from app.services.lecture_agent import generate_lecture_turns

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

    第五轮新增：把当前题目内的「学生上一轮说了什么 / AI 上一轮追问了什么」一并随
    `/lecture/submit` 上传，让后端 LLM 不再每次「失忆式」追问同一个问题。

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

    # 第五轮新增可选字段：保持旧 Flutter 客户端不传这两个字段也能通过。
    # `round_index` 从 1 开始，第一次提交是第 1 轮；第二次提交（学生在回答 AI 追问）
    # 应当是 2，依此类推。这个语义对 Prompt 工程很关键 ——「回答上一轮追问」与
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
    turns: list[AgentTurnOut]

    model_config = {
        "populate_by_name": True,
    }


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------


_SUPPORTED_SECTIONS: tuple[str, ...] = (
    "pep-g8-down-s16-1",
    "pep-g8-down-s16-2",
    "pep-g8-down-s16-3",
)


@router.post(
    "/submit",
    response_model=LectureSubmitResponse,
    response_model_by_alias=True,
    summary="提交学生讲解 → LLM 生成多 Agent 追问（失败回退固定 Mock）",
)
async def submit_lecture(
    req: LectureSubmitRequest,
    user: User | None = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> LectureSubmitResponse:
    if req.section_id not in _SUPPORTED_SECTIONS:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=(
                f"Section '{req.section_id}' is not part of the V1 launch scope. "
                f"Supported sections: {list(_SUPPORTED_SECTIONS)}"
            ),
        )

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

    result = generate_lecture_turns(
        section_id=req.section_id,
        question_id=req.question_id,
        question_prompt=req.question_prompt,
        student_speech_text=req.student_speech_text,
        steps=steps_payload,
        round_index=req.round_index,
        history=history_payload,
    )

    logger.info(
        "[lecture] /submit section=%s question=%s round=%d steps=%d "
        "history=%d source=%s status=%s turns=%d",
        req.section_id,
        req.question_id,
        req.round_index,
        len(req.steps),
        len(req.history),
        result.get("source"),
        result.get("status"),
        len(result.get("turns", [])),
    )

    turns = [
        AgentTurnOut(
            turn_id=t["turn_id"],
            role=t["role"],
            display_name=t["display_name"],
            text=t["text"],
            highlight_step_ids=t.get("highlight_step_ids", []),
        )
        for t in result.get("turns", [])
    ]

    # 第十轮：带 Bearer 时把本次提交落进 LectureSessionRecord +
    # 实时更新 LearningProgress；匿名调用仍然走原路径，与现有
    # /lecture/submit 演示链路完全兼容。
    if user is not None:
        try:
            _persist_lecture_submission(
                db=db,
                user=user,
                req=req,
                steps_payload=steps_payload,
                turns_payload=result.get("turns", []),
                status_value=result.get("status", "needs_explanation"),
                mastery_delta=int(result.get("mastery_delta", 0) or 0),
            )
        except Exception as e:  # noqa: BLE001
            # 持久化失败绝不影响 Demo 链路：吞掉异常打 warning。
            logger.warning(
                "[lecture] persist submission failed user=%s err=%s",
                user.username,
                e,
            )

    return LectureSubmitResponse(
        question_id=req.question_id,
        section_id=req.section_id,
        status=result.get("status", "needs_explanation"),
        mastery_delta=result.get("mastery_delta", 0),
        turns=turns,
    )


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

    db.commit()
