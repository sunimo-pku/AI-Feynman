"""白板 OCR / Ink Parser（第十轮 + Qwen-VL HWR）。

V1 没有真实专用 HWR 引擎时，**禁止**把题目的 `referenceSteps` 当成学生
手写内容回填到 `latex` / `plainText`——否则同伴会把「写出已知」这类
解题框架标签误说成「你白板上写了…」。

- `mode=rule`（默认）：只上报 step 结构（stepId / strokeCount），识别
  字段留空；
- `mode=hwr`：有 `ALIYUN_API_KEY` 且 step 带 PNG `imageBase64` 时走
  Qwen-VL 视觉识别；失败或未配置时返回空，不拿 referenceSteps 凑数；
- 永远返回 200，失败 step 的 `latex` / `plainText` 留空，调用方继续走
  「笔画数 + 音频」追问。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.config import Config
from app.services.qwen_vision import recognize_ink_step

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


class InkResponse(BaseModel):
    steps: list[InkStepOut]
    section_id: str = Field(..., serialization_alias="sectionId")

    model_config = {"populate_by_name": True}


def _plain_for(latex: str) -> str:
    """非常粗的 LaTeX → 普通话翻译。仅给 LLM 做一手语义证据用，
    学生 / 家长不会直接看到这段文字。"""

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


def _recognize_step_with_qwen(
    *,
    step: InkStepIn,
    section_id: str,
    question_id: str,
    reference_hints: list[str],
) -> InkStepOut:
    vision = recognize_ink_step(
        image_base64=step.image_base64,
        section_id=section_id,
        question_id=question_id,
        reference_hints=reference_hints,
    )
    if vision.get("error"):
        logger.info(
            "[ocr-ink] qwen_vl_skip step=%s err=%s",
            step.step_id,
            vision.get("error"),
        )
        return InkStepOut(
            step_id=step.step_id,
            latex="",
            plain_text="",
            confidence=0.0,
            source="empty",
            mode="hwr",
        )

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

    return InkStepOut(
        step_id=step.step_id,
        latex=latex,
        plain_text=plain,
        confidence=conf,
        source=source,
        mode="hwr",
    )


def recognize_steps(req: InkRequest) -> list[InkStepOut]:
    """V1 OCR 主入口。

    无真实 HWR 结果时一律返回空 latex/plainText。`referenceSteps` 仅作
    Qwen-VL prompt 里的题型对照 hint，**不得**写入学生 step 字段。
    """

    out: list[InkStepOut] = []
    if not req.steps:
        return out

    refs = [r.strip() for r in req.reference_steps if isinstance(r, str)]
    refs = [r for r in refs if r]

    for step in req.steps:
        latex = ""
        plain = ""
        source = "empty"
        confidence = 0.0
        mode = req.mode

        if req.mode == "hwr" and step.image_base64 and Config.ALIYUN_API_KEY:
            recognized = _recognize_step_with_qwen(
                step=step,
                section_id=req.section_id,
                question_id=req.question_id,
                reference_hints=refs,
            )
            out.append(recognized)
            logger.info(
                "[ocr-ink] step=%s source=%s conf=%.2f mode=%s",
                step.step_id,
                recognized.source,
                recognized.confidence,
                recognized.mode,
            )
            continue

        if req.mode == "hwr" and step.image_base64 and not Config.ALIYUN_API_KEY:
            logger.info(
                "[ocr-ink] hwr_no_vision_key step=%s",
                step.step_id,
            )

        out.append(
            InkStepOut(
                step_id=step.step_id,
                latex=latex,
                plain_text=plain,
                confidence=confidence,
                source=source,
                mode=mode,
            )
        )
        logger.info(
            "[ocr-ink] step=%s source=%s conf=%.2f mode=%s",
            step.step_id,
            source,
            confidence,
            mode,
        )
    return out


@router.post(
    "/ink",
    response_model=InkResponse,
    response_model_by_alias=True,
    summary="白板 ink → 结构化 LaTeX/plainText（Qwen-VL HWR）",
)
async def ocr_ink(req: InkRequest) -> InkResponse:
    steps_out = recognize_steps(req)
    logger.info(
        "[ocr-ink] section=%s steps_in=%d refs=%d steps_out=%d",
        req.section_id,
        len(req.steps),
        len(req.reference_steps),
        len(steps_out),
    )
    return InkResponse(section_id=req.section_id, steps=steps_out)
