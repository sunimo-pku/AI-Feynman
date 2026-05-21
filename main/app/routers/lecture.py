"""讲题 / 多 Agent 追问的 Mock 后端。

第二轮目标：把第一轮的本地 Mock 多 Agent 回复迁到后端，**只稳定前后端契约**，
暂不接真实 LLM。设计要点：

- 路由前缀使用业务语义 `/lecture`，避免与 `/chat` 通用对话端点混淆。
- 强 Schema：Pydantic v2 模型，所有字段显式声明，前端就能直接 from_json。
- 不引入 `require_user`：当前 Flutter 客户端尚未做登录态，演示链路不应被 401 拦腰截断。
- 仅 1 个章节维度 if/else，未来替换为真实 LLM 时只需保留 `LectureSubmitResponse`
  契约即可逐字段对齐。
- 错误：参数缺失走 422（由 FastAPI / Pydantic 自动产生）；
       未知章节走 404；空步骤数组走 400 —— 全部经 HTTPException 抛出，
       不走 `return {"error": ...}` 假 200。
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

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
# Mock 多 Agent 剧本（按 sectionId 选取）
# ---------------------------------------------------------------------------


def _build_turns(section_id: str, step_ids: list[str]) -> list[AgentTurnOut]:
    """根据章节 + 学生步骤数组，生成 2 条固定 Mock 对话。

    `highlightStepIds` 必须命中真实存在的 stepId，前端才能让画布对应笔迹亮起。
    """

    first_step = step_ids[0] if step_ids else "step_1"
    mid_step = step_ids[len(step_ids) // 2] if step_ids else first_step
    last_step = step_ids[-1] if step_ids else first_step

    if section_id == "pep-g8-down-s16-1":
        return [
            AgentTurnOut(
                turn_id="turn_1",
                role="xiaoming",
                display_name="小明",
                text=(
                    "等等，被开方数是 2x-6，你怎么知道一定要让它 ≥ 0 呀？"
                    "是不是因为负数开根号在实数范围里没意义？"
                ),
                highlight_step_ids=[first_step],
            ),
            AgentTurnOut(
                turn_id="turn_2",
                role="teacher",
                display_name="李老师",
                text=(
                    "问得不错。你能不能再补一句：写完不等式 $2x-6 \\ge 0$ 之后，"
                    "怎么推出 $x \\ge 3$？"
                ),
                highlight_step_ids=[last_step],
            ),
        ]
    if section_id == "pep-g8-down-s16-2":
        return [
            AgentTurnOut(
                turn_id="turn_1",
                role="xiaoming",
                display_name="小明",
                text=(
                    "你直接把 $\\sqrt{12} \\cdot \\sqrt{3}$ 写成 $\\sqrt{36}$，"
                    "这里用了一条法则吧？前提是什么呀？"
                ),
                highlight_step_ids=[first_step],
            ),
            AgentTurnOut(
                turn_id="turn_2",
                role="teacher",
                display_name="李老师",
                text=(
                    "对的，要强调 $a \\ge 0$、$b \\ge 0$ 才能这样合并。"
                    "你能把这句条件补到你刚才那一步旁边吗？"
                ),
                highlight_step_ids=[mid_step],
            ),
        ]
    if section_id == "pep-g8-down-s16-3":
        return [
            AgentTurnOut(
                turn_id="turn_1",
                role="xiaoming",
                display_name="小明",
                text=(
                    "我有点疑惑，$\\sqrt{12}$ 为什么可以变成 $2\\sqrt{3}$？"
                    "这里用了什么规律？"
                ),
                highlight_step_ids=[first_step],
            ),
            AgentTurnOut(
                turn_id="turn_2",
                role="teacher",
                display_name="李老师",
                text=(
                    "这个问题问得很好。你可以试着把 12 拆成 $4 \\times 3$，"
                    "再说明为什么 4 能从根号里出来。同样地，$\\sqrt{27}$ 也试一下。"
                ),
                highlight_step_ids=[mid_step],
            ),
        ]
    return []


_SUPPORTED_SECTIONS: tuple[str, ...] = (
    "pep-g8-down-s16-1",
    "pep-g8-down-s16-2",
    "pep-g8-down-s16-3",
)


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------


@router.post(
    "/submit",
    response_model=LectureSubmitResponse,
    response_model_by_alias=True,
    summary="提交学生讲解 → 返回多 Agent Mock 追问",
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

    step_ids = [s.step_id for s in req.steps]
    turns = _build_turns(req.section_id, step_ids)

    return LectureSubmitResponse(
        question_id=req.question_id,
        section_id=req.section_id,
        status="needs_explanation",
        mastery_delta=0,
        turns=turns,
    )
