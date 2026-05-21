"""讲题 / 多 Agent 追问路由。

- 第二轮：返回固定 JSON Mock。
- 第三轮（当前）：交由 `services.lecture_agent.generate_lecture_turns(...)`
  调用真实 LLM 生成强结构化多 Agent 追问；LLM 不可用 / 解析失败 / 校验失败时
  自动回退到第二轮的固定 Mock，保证 Demo 链路不中断。

设计要点：

- 路由前缀使用业务语义 `/lecture`，避免与 `/chat` 通用对话端点混淆。
- 强 Schema：Pydantic v2 模型，所有字段显式声明，前端就能直接 from_json。
- 不引入 `require_user`：当前 Flutter 客户端尚未做登录态，演示链路不应被 401 拦腰截断。
- 错误：参数缺失走 422（由 FastAPI / Pydantic 自动产生）；
       未知章节走 404；空步骤数组走 400 —— 全部经 HTTPException 抛出，
       不走 `return {"error": ...}` 假 200。
- LLM 错误**不**抛 HTTPException：会让前端看到红色错误条，破坏 Demo；
  统一由 service 回落 fallback，路由层只看 `source` 字段写日志。
"""

from __future__ import annotations

import logging
from typing import Literal

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

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


class LectureSubmitRequest(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_id: str = Field(..., alias="questionId", min_length=1, max_length=64)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    student_speech_text: str = Field("", alias="studentSpeechText", max_length=4000)
    steps: list[LectureStep] = Field(default_factory=list)

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
async def submit_lecture(req: LectureSubmitRequest) -> LectureSubmitResponse:
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

    result = generate_lecture_turns(
        section_id=req.section_id,
        question_id=req.question_id,
        question_prompt=req.question_prompt,
        student_speech_text=req.student_speech_text,
        steps=steps_payload,
    )

    logger.info(
        "[lecture] /submit section=%s question=%s steps=%d source=%s turns=%d",
        req.section_id,
        req.question_id,
        len(req.steps),
        result.get("source"),
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

    return LectureSubmitResponse(
        question_id=req.question_id,
        section_id=req.section_id,
        status=result.get("status", "needs_explanation"),
        mastery_delta=result.get("mastery_delta", 0),
        turns=turns,
    )
