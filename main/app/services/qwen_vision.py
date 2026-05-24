"""Qwen-VL based photo question recognition and whiteboard ink HWR."""

from __future__ import annotations

import base64
import json
import logging
import re
from typing import Any

from openai import OpenAI

from app.config import Config

logger = logging.getLogger(__name__)

_JSON_RE = re.compile(r"\{.*\}", re.DOTALL)
_MIN_INK_IMAGE_BYTES = 64


def recognize_question_image(
    *,
    image_base64: str,
    mime_type: str,
) -> dict[str, Any]:
    """Recognize a photographed math question using Alibaba Qwen-VL.

    Returns a normalized payload compatible with `/questions/upload-image`.
    Any exception is converted to an `error` field so callers can surface an
    explicit upstream failure.
    """

    if not Config.ALIYUN_API_KEY:
        return {"error": "ALIYUN_API_KEY not configured"}
    if not image_base64:
        return {"error": "empty image"}

    client = OpenAI(api_key=Config.ALIYUN_API_KEY, base_url=Config.ALIYUN_BASE_URL)
    data_url = f"data:{mime_type or 'image/jpeg'};base64,{image_base64}"
    prompt = """
你是初中数学题目识别助手。请识别图片中的题目，并判断它最可能属于人教版初中数学哪个小节。
请根据题面内容、章节知识点和年级范围判断 sectionId。

sectionId 命名规则：pep-g{7|8|9}-{up|down}-s{章号}-{节号}
例子：
- 七年级上册 1.3 有理数的加减法：pep-g7-up-s1-3
- 八年级上册 12.1 全等三角形：pep-g8-up-s12-1
- 八年级下册 18.1 平行四边形：pep-g8-down-s18-1
- 九年级上册 22.1 二次函数的图像和性质：pep-g9-up-s22-1
- 九年级下册 27.1 图形的相似：pep-g9-down-s27-1

只输出 JSON 对象，不要 Markdown：
{
  "sectionId": "pep-g7-up-s1-1|pep-g8-up-s12-1|pep-g9-down-s27-1|unknown",
  "questionPrompt": "识别出的题面，数学符号尽量用 LaTeX",
  "knowledgeTags": ["标签1", "标签2"],
  "confidence": 0.0
}
如果图片不是数学题或看不清，sectionId 用 "unknown"，confidence <= 0.3。
""".strip()
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(
            model=Config.QWEN_VL_MODEL,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": data_url}},
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
            temperature=0.1,
            max_tokens=512,
            timeout=30.0,
        )
        raw = (resp.choices[0].message.content or "").strip()
        parsed = _parse_json(raw)
        section_id = str(parsed.get("sectionId") or "unknown")
        tags_raw = parsed.get("knowledgeTags")
        tags = [
            str(t).strip()
            for t in (tags_raw if isinstance(tags_raw, list) else [])
            if str(t).strip()
        ]
        confidence = parsed.get("confidence", 0.0)
        try:
            conf = max(0.0, min(1.0, float(confidence)))
        except (TypeError, ValueError):
            conf = 0.5
        question_prompt = str(parsed.get("questionPrompt") or "").strip()
        if not question_prompt:
            question_prompt = "请确认图片题目并开始讲解。"
        logger.info(
            "[qwen-vision] source=qwen_vl section=%s conf=%.2f",
            section_id,
            conf,
        )
        return {
            "sectionId": section_id,
            "knowledgeTags": tags or ["图片识题"],
            "questionPrompt": question_prompt,
            "confidence": conf,
            "source": "qwen_vl",
        }
    except Exception as e:  # noqa: BLE001
        logger.exception("[qwen-vision] failed: %s", e)
        return {"error": f"qwen_vl_error:{e}"}


def recognize_ink_step(
    *,
    image_base64: str,
    section_id: str = "",
    question_id: str = "",
) -> dict[str, Any]:
    """Recognize one whiteboard step handwriting via Qwen-VL.

    Returns normalized ``latex`` / ``plainText`` / ``confidence`` / ``source``.
    Failures surface as ``error`` so callers can keep the lecture flow alive.

    注意：不要把题库 referenceSteps 传进 prompt —— 其中常含标准答案 LaTeX，
    会诱发 VL 模型「抄答案」而非读笔迹。
    """

    if not Config.ALIYUN_API_KEY:
        return {"error": "ALIYUN_API_KEY not configured"}
    if not image_base64:
        return {"error": "empty image"}

    try:
        raw = base64.b64decode(image_base64, validate=True)
    except Exception:  # noqa: BLE001
        return {"error": "invalid base64"}
    if len(raw) < _MIN_INK_IMAGE_BYTES:
        return {"error": "image too small"}

    prompt = f"""
你是初中数学手写识别助手。图片是学生白板上的**一步**手写内容（算式、等式或简短中文说明）。
请识别学生**实际写了什么**，只输出 JSON 对象，不要 Markdown：
{{
  "latex": "尽量用 LaTeX，如 \\\\sqrt{{12}}=2\\\\sqrt{{3}}；若主要是中文步骤说明则留空",
  "plainText": "一步的中文说明；若主要是公式，用普通话简述",
  "confidence": 0.0
}}
规则：
- 只认图片里的真实笔迹，禁止编造。
- 看不清、空白或无法辨认时 latex/plainText 留空，confidence <= 0.2。
- 不要根据题面或解题套路猜测学生写了什么。
sectionId={section_id or "unknown"} questionId={question_id or "unknown"}
""".strip()

    client = OpenAI(api_key=Config.ALIYUN_API_KEY, base_url=Config.ALIYUN_BASE_URL)
    data_url = f"data:image/png;base64,{image_base64}"
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(
            model=Config.QWEN_VL_MODEL,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": data_url}},
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
            temperature=0.1,
            max_tokens=384,
            timeout=20.0,
        )
        raw_text = (resp.choices[0].message.content or "").strip()
        parsed = _parse_json(raw_text)
        latex = str(parsed.get("latex") or "").strip()
        plain = str(parsed.get("plainText") or parsed.get("plain_text") or "").strip()
        confidence = parsed.get("confidence", 0.0)
        try:
            conf = max(0.0, min(1.0, float(confidence)))
        except (TypeError, ValueError):
            conf = 0.55 if latex or plain else 0.0
        if not latex and not plain:
            conf = min(conf, 0.2)
        logger.info(
            "[qwen-vision] ink step=%s section=%s conf=%.2f latex_len=%d plain_len=%d",
            question_id,
            section_id,
            conf,
            len(latex),
            len(plain),
        )
        return {
            "latex": latex,
            "plainText": plain,
            "confidence": conf,
            "source": "qwen_vl" if latex or plain else "empty",
        }
    except Exception as e:  # noqa: BLE001
        logger.warning("[qwen-vision] ink failed section=%s: %s", section_id, e)
        return {"error": f"qwen_vl_error:{e}"}


def recognize_ink_board(
    *,
    image_base64: str,
    section_id: str = "",
    question_id: str = "",
    question_prompt: str = "",
    section_label: str = "",
    knowledge_tags: list[str] | None = None,
) -> dict[str, Any]:
    """Recognize the full whiteboard handwriting in one Qwen-VL call.

    不传题库 referenceSteps：其中常含 $\\\\sqrt{{12}}=2\\\\sqrt{{3}}$ 等标准答案，
    VL 模型极易误当成 OCR 结果输出。
    """

    if not Config.ALIYUN_API_KEY:
        return {"error": "ALIYUN_API_KEY not configured"}
    if not image_base64:
        return {"error": "empty image"}

    try:
        raw = base64.b64decode(image_base64, validate=True)
    except Exception:  # noqa: BLE001
        return {"error": "invalid base64"}
    if len(raw) < _MIN_INK_IMAGE_BYTES:
        return {"error": "image too small"}

    tags = [
        str(tag).strip()
        for tag in (knowledge_tags or [])
        if str(tag).strip()
    ][:8]
    context_lines = [
        f"当前小节：{section_label or section_id or 'unknown'}",
        f"知识点：{'、'.join(tags) if tags else 'unknown'}",
        f"原题题面：{question_prompt.strip() or 'unknown'}",
    ]

    prompt = f"""
你是初中数学手写识别助手。图片是学生讲题白板的**完整内容**（可能含多行算式与简短中文说明）。
下面是题目上下文，只能用于辨别白板里模糊的符号、变量、上下标和阅读顺序：
{chr(10).join(context_lines)}

请识别学生**实际写了什么**，只输出 JSON 对象，不要 Markdown：
{{
  "latex": "尽量用 LaTeX 概括整板主要算式；若主要是中文步骤说明则留空",
  "plainText": "用中文概括整板写了什么（按从上到下阅读顺序）",
  "confidence": 0.0
}}
规则：
- 只认图片里的真实笔迹，禁止编造。
- 只允许用原题上下文做符号消歧，不能补全学生没写在白板上的步骤、答案或推理。
- 如果题面里有某个公式但白板没有写，禁止把它输出成学生白板内容。
- 看不清、空白或无法辨认时 latex/plainText 留空，confidence <= 0.2。
- 不要根据题面、章节或解题套路猜测学生写了什么。
sectionId={section_id or "unknown"} questionId={question_id or "unknown"}
""".strip()

    client = OpenAI(api_key=Config.ALIYUN_API_KEY, base_url=Config.ALIYUN_BASE_URL)
    data_url = f"data:image/png;base64,{image_base64}"
    try:
        resp = client.with_options(max_retries=0).chat.completions.create(
            model=Config.QWEN_VL_MODEL,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": data_url}},
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
            temperature=0.1,
            max_tokens=512,
            timeout=25.0,
        )
        raw_text = (resp.choices[0].message.content or "").strip()
        parsed = _parse_json(raw_text)
        latex = str(parsed.get("latex") or "").strip()
        plain = str(parsed.get("plainText") or parsed.get("plain_text") or "").strip()
        confidence = parsed.get("confidence", 0.0)
        try:
            conf = max(0.0, min(1.0, float(confidence)))
        except (TypeError, ValueError):
            conf = 0.55 if latex or plain else 0.0
        if not latex and not plain:
            conf = min(conf, 0.2)
        logger.info(
            "[qwen-vision] board section=%s conf=%.2f latex_len=%d plain_len=%d",
            section_id,
            conf,
            len(latex),
            len(plain),
        )
        return {
            "latex": latex,
            "plainText": plain,
            "confidence": conf,
            "source": "qwen_vl" if latex or plain else "empty",
        }
    except Exception as e:  # noqa: BLE001
        logger.warning("[qwen-vision] board failed section=%s: %s", section_id, e)
        return {"error": f"qwen_vl_error:{e}"}


def _parse_json(raw: str) -> dict[str, Any]:
    try:
        decoded = json.loads(raw)
        return decoded if isinstance(decoded, dict) else {}
    except Exception:  # noqa: BLE001
        match = _JSON_RE.search(raw)
        if not match:
            return {}
        try:
            decoded = json.loads(match.group(0))
            return decoded if isinstance(decoded, dict) else {}
        except Exception:  # noqa: BLE001
            return {}
