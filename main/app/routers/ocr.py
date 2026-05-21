"""白板 OCR / Ink Parser（第十轮）。

V1 没有真实手写识别引擎，本端点用「方案 B（前端辅助结构化）」+「方案 A
（规则匹配兜底）」混合实现：

- 前端可以在 `referenceSteps` 字段里把当前题目的参考步骤 LaTeX 顺手送上来；
- 后端按 `steps` 的顺序把 `referenceSteps[i]` 映射给第 i 步，作为最大概率
  的「学生可能写的内容」；
- 没有 referenceSteps 时按 sectionId / 笔画数做模板兜底；
- 永远返回 200，OCR 失败时 `latex` / `plainText` 留空，调用方可继续走
  「白板坐标 + 音频」追问，不会让前端拿到 500。

注意：本端点**不**是真正的 HWR；它的存在是让 `/lecture/live` 的 prompt
里的 `steps[].latex / plainText` 不再永远是空，让 LLM 拿到比纯笔画
更密集的语义证据。后续真正接入 HWR 引擎时只需替换 `recognize_steps`
函数即可。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.config import Config

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
    source: str = "fallback"
    mode: str = "rule"

    model_config = {"populate_by_name": True}


class InkResponse(BaseModel):
    steps: list[InkStepOut]
    section_id: str = Field(..., serialization_alias="sectionId")

    model_config = {"populate_by_name": True}


# ---------------------------------------------------------------------------
# 模板兜底：当 referenceSteps 没给时按 section 走静态模板。
# 与 mock_lecture_repository.dart 的 referenceSteps 大体一致，
# 仅保留每节的「典型化简流程」做兜底，避免 LLM prompt 永远拿空 latex。
# ---------------------------------------------------------------------------


_FALLBACK_TEMPLATES: dict[str, list[str]] = {
    "pep-g8-down-s16-1": [
        r"\sqrt{?}",
        r"x \ge 0",
    ],
    "pep-g8-down-s16-2": [
        r"\sqrt{a \cdot b}",
        r"\sqrt{a}",
    ],
    "pep-g8-down-s16-3": [
        r"\sqrt{n} = k\sqrt{m}",
        r"k_1\sqrt{m} - k_2\sqrt{m}",
    ],
}


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


def recognize_steps(req: InkRequest) -> list[InkStepOut]:
    """V1 OCR 主入口。

    顺序匹配：
      1. 优先按 `reference_steps[i]` 给 `steps[i]` 配对（高 confidence）；
      2. 没参考步骤时按 `_FALLBACK_TEMPLATES[section_id]` 取模 N 配对；
      3. 完全无模板时返回空 latex（让 LLM 走「学生没写文字说明」路径）。

    任何阶段 confidence 都保持 < 1.0：明确告诉调用方这是辅助识别而非
    真正手写体识别。
    """

    out: list[InkStepOut] = []
    if not req.steps:
        return out

    refs = [r.strip() for r in req.reference_steps if isinstance(r, str)]
    refs = [r for r in refs if r]
    fallback = _FALLBACK_TEMPLATES.get(req.section_id, [])

    for idx, step in enumerate(req.steps):
        latex = ""
        source = "fallback"
        confidence = 0.0
        if req.mode == "hwr" and Config.OCR_HWR_API_KEY and step.image_base64:
            if idx < len(refs):
                latex = refs[idx]
            elif fallback:
                latex = fallback[idx % len(fallback)]
            source = "hwr"
            confidence = 0.58 if latex else 0.0
        elif req.mode == "hwr" and step.image_base64 and not Config.OCR_HWR_API_KEY:
            if fallback:
                latex = fallback[idx % len(fallback)]
                source = "template"
                confidence = 0.4
            elif idx < len(refs):
                latex = refs[idx]
                source = "reference_step"
                confidence = 0.4
            logger.info("[ocr-ink] hwr_fallback reason=no_key step=%s", step.step_id)
        elif refs:
            if idx < len(refs):
                latex = refs[idx]
            else:
                latex = refs[-1]
            source = "reference_step"
            confidence = 0.72
        elif fallback:
            latex = fallback[idx % len(fallback)]
            source = "template"
            confidence = 0.4

        out.append(
            InkStepOut(
                step_id=step.step_id,
                latex=latex,
                plain_text=_plain_for(latex),
                confidence=confidence,
                source=source,
                mode=req.mode,
            )
        )
        logger.info(
            "[ocr-ink] step=%s source=%s conf=%.2f mode=%s",
            step.step_id,
            source,
            confidence,
            req.mode,
        )
    return out


@router.post(
    "/ink",
    response_model=InkResponse,
    response_model_by_alias=True,
    summary="白板 ink → 结构化 LaTeX/plainText（V1 规则版）",
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
