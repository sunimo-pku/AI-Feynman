"""题库索引：按 questionId 读取标准解答要点（供讲题评估核对）。"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_QUESTIONS_FILE = _PROJECT_ROOT / "data" / "questions" / "pep-junior-math-questions.json"


@lru_cache(maxsize=1)
def _load_questions_index() -> dict[str, str]:
    try:
        raw = json.loads(_QUESTIONS_FILE.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        logger.warning("[question-bank] load failed: %s", e)
        return {}
    out: dict[str, str] = {}
    for item in raw.get("questions", []) if isinstance(raw, dict) else []:
        if not isinstance(item, dict):
            continue
        qid = str(item.get("questionId") or item.get("id") or "").strip()
        answer = str(item.get("standardAnswer") or "").strip()
        if qid and answer:
            out[qid] = answer
    return out


def is_usable_standard_answer(text: str) -> bool:
    """占位文案不算可用标准答案。"""
    t = (text or "").strip()
    if not t:
        return False
    if "将于后续版本填入" in t:
        return False
    return True


def standard_answer_for_question(question_id: str) -> str:
    return _load_questions_index().get(str(question_id or "").strip(), "")


def resolve_standard_answer(*, question_id: str, client_answer: str = "") -> str:
    """客户端上送优先；否则读本地题库。"""
    client = (client_answer or "").strip()
    if is_usable_standard_answer(client):
        return client
    bank = standard_answer_for_question(question_id)
    if is_usable_standard_answer(bank):
        return bank
    return ""
