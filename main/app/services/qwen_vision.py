"""Qwen-VL based photo question recognition."""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from openai import OpenAI

from app.config import Config

logger = logging.getLogger(__name__)

_JSON_RE = re.compile(r"\{.*\}", re.DOTALL)


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
