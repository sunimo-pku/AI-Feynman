"""白板 OCR / Ink Parser（整板 Qwen-VL HWR）。

V1 白板识别：**整板 PNG 一次 OCR**，不按 step 裁切多次识别。
`referenceSteps` 仅作 Qwen-VL prompt 里的题型对照 hint，**不得**写入学生字段。

- `mode=rule`（默认）：只上报 step 结构（stepId / strokeCount），识别字段留空；
- `mode=hwr`：有 `boardImageBase64` + `ALIYUN_API_KEY` 时整板走 Qwen-VL；
  失败或未配置时 `board` 留空，不拿 referenceSteps 凑数；
- 永远返回 200，失败时 latex/plainText 留空，调用方继续走「笔画数 + 音频」。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.config import Config
from app.services.qwen_vision import recognize_ink_board

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ocr", tags=["OCR"])


class InkStepIn(BaseModel):
    step_id: str = Field(..., alias="stepId", min_length=1, max_length=64)
    stroke_count: int = Field(0, alias="strokeCount", ge=0)
    bounding_box: dict | None = Field(None, alias="boundingBox")
    image_base64: str = Field("", alias="imageBase64")

    model_config = {"populate_by_name": True}


class InkRequest(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_id: str = Field("", alias="questionId", max_length=64)
    mode: str = Field("rule", pattern="^(rule|hwr)$")
    board_image_base64: str = Field("", alias="boardImageBase64")
    reference_steps: list[str] = Field(
        default_factory=list,
        alias="referenceSteps",
    )
    steps: list[InkStepIn] = Field(default_factory=list)

    model_config = {"populate_by_name": True}


class InkStepOut(BaseModel):
    step_id: str = Field(..., serialization_alias="stepId")
    latex: str = ""
    plain_text: str = Field("", serialization_alias="plainText")
    confidence: float = 0.0
    source: str = "empty"
    mode: str = "rule"

    model_config = {"populate_by_name": True}


class InkBoardOut(BaseModel):
    latex: str = ""
    plain_text: str = Field("", serialization_alias="plainText")
    confidence: float = 0.0
    source: str = "empty"
    mode: str = "hwr"

    model_config = {"populate_by_name": True}


class InkResponse(BaseModel):
    steps: list[InkStepOut]
    board: InkBoardOut | None = None
    section_id: str = Field(..., serialization_alias="sectionId")

    model_config = {"populate_by_name": True}


def _plain_for(latex: str) -> str:
    if not latex:
        return ""
    s = latex
    s = s.replace(r"\sqrt", "根号")
    s = s.replace(r"\ge", " 大于等于 ")
    s = s.replace(r"\le", " 小于等于 ")
    s = s.replace(r"\cdot", " 乘 ")
    s = s.replace(r"\frac", "分之")
    s = s.replace("{", "(").replace("}", ")")
    return s.strip()


def _empty_board(mode: str = "hwr") -> InkBoardOut:
    return InkBoardOut(
        latex="",
        plain_text="",
        confidence=0.0,
        source="empty",
        mode=mode,
    )


def _recognize_board_with_qwen(
    *,
    board_image_base64: str,
    section_id: str,
    question_id: str,
) -> InkBoardOut:
    vision = recognize_ink_board(
        image_base64=board_image_base64,
        section_id=section_id,
        question_id=question_id,
    )
    if vision.get("error"):
        logger.info(
            "[ocr-ink] qwen_vl_board_skip section=%s err=%s",
            section_id,
            vision.get("error"),
        )
        return _empty_board()

    latex = str(vision.get("latex") or "").strip()
    plain = str(vision.get("plainText") or vision.get("plain_text") or "").strip()
    if latex and not plain:
        plain = _plain_for(latex)
    try:
        conf = max(0.0, min(1.0, float(vision.get("confidence") or 0.0)))
    except (TypeError, ValueError):
        conf = 0.55 if latex or plain else 0.0
    source = str(vision.get("source") or ("qwen_vl" if latex or plain else "empty"))
    if not latex and not plain:
        source = "empty"
        conf = 0.0

    return InkBoardOut(
        latex=latex,
        plain_text=plain,
        confidence=conf,
        source=source,
        mode="hwr",
    )


def recognize_steps(req: InkRequest) -> tuple[list[InkStepOut], InkBoardOut | None]:
    """V1 OCR 主入口：整板识别一次；steps 只回传结构字段。"""

    board: InkBoardOut | None = None
    if (
        req.mode == "hwr"
        and req.board_image_base64.strip()
        and Config.ALIYUN_API_KEY
    ):
        # referenceSteps 留在请求体供兼容；HWR 不传 Qwen-VL，避免抄标准答案。
        board = _recognize_board_with_qwen(
            board_image_base64=req.board_image_base64.strip(),
            section_id=req.section_id,
            question_id=req.question_id,
        )
        logger.info(
            "[ocr-ink] board section=%s source=%s conf=%.2f mode=hwr",
            req.section_id,
            board.source,
            board.confidence,
        )
    elif req.mode == "hwr" and req.board_image_base64.strip() and not Config.ALIYUN_API_KEY:
        logger.info("[ocr-ink] hwr_no_vision_key section=%s", req.section_id)
        board = _empty_board()

    out: list[InkStepOut] = []
    for step in req.steps:
        out.append(
            InkStepOut(
                step_id=step.step_id,
                latex="",
                plain_text="",
                confidence=0.0,
                source="empty",
                mode=req.mode,
            )
        )
        logger.info(
            "[ocr-ink] step=%s source=empty conf=0.00 mode=%s strokes=%d",
            step.step_id,
            req.mode,
            step.stroke_count,
        )
    return out, board


@router.post(
    "/ink",
    response_model=InkResponse,
    response_model_by_alias=True,
    summary="白板 ink → 整板 LaTeX/plainText（Qwen-VL HWR）",
)
async def ocr_ink(req: InkRequest) -> InkResponse:
    steps_out, board_out = recognize_steps(req)
    logger.info(
        "[ocr-ink] section=%s steps_in=%d refs=%d board=%s",
        req.section_id,
        len(req.steps),
        len(req.reference_steps),
        "yes" if board_out and board_out.source != "empty" else "no",
    )
    return InkResponse(
        section_id=req.section_id,
        steps=steps_out,
        board=board_out,
    )
