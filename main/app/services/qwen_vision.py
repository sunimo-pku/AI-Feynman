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
    Any exception is converted to an `error` field so callers can fall back to
    the local demo path without breaking the app.
    """

    if not Config.ALIYUN_API_KEY:
        return {"error": "ALIYUN_API_KEY not configured"}
    if not image_base64:
        return {"error": "empty image"}

    client = OpenAI(api_key=Config.ALIYUN_API_KEY, base_url=Config.ALIYUN_BASE_URL)
    data_url = f"data:{mime_type or 'image/jpeg'};base64,{image_base64}"
    prompt = """
你是初中数学题目识别助手。请识别图片中的题目，并判断它最可能属于哪个人教版初中数学小节。
当前 App 最完整支持二次根式三节：
- pep-g8-down-s16-1：二次根式的概念与取值范围
- pep-g8-down-s16-2：二次根式的乘除
- pep-g8-down-s16-3：二次根式的加减

只输出 JSON 对象，不要 Markdown：
{
  "sectionId": "pep-g8-down-s16-1|pep-g8-down-s16-2|pep-g8-down-s16-3|unknown",
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
        if section_id == "unknown":
            section_id = "pep-g8-down-s16-3"
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
