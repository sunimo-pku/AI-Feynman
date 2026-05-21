"""Local textbook knowledge index used by search and lecture prompts."""

from __future__ import annotations

import json
import logging
import math
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_KNOWLEDGE_DIR = _PROJECT_ROOT / "data" / "knowledge"


def _load_chunks() -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    if not _KNOWLEDGE_DIR.exists():
        logger.warning("[knowledge-index] missing dir=%s", _KNOWLEDGE_DIR)
        return chunks
    for path in sorted(_KNOWLEDGE_DIR.glob("*_chunks.json")):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            logger.warning("[knowledge-index] load failed path=%s err=%s", path, e)
            continue
        if not isinstance(raw, list):
            continue
        for item in raw:
            if not isinstance(item, dict):
                continue
            chunk_id = str(item.get("id") or "").strip()
            section_id = str(item.get("sectionId") or item.get("section_id") or "").strip()
            text = str(item.get("text") or "").strip()
            if not chunk_id or not section_id or not text:
                continue
            chunks.append({
                "id": chunk_id,
                "sectionId": section_id,
                "title": str(item.get("title") or "").strip(),
                "text": text,
                "keywords": [
                    str(k).strip()
                    for k in (item.get("keywords") or [])
                    if str(k).strip()
                ],
            })
    logger.info("[knowledge-index] loaded chunks=%d", len(chunks))
    return chunks


_CHUNKS = _load_chunks()


def reload_for_testing() -> None:
    """Reload JSON chunks for tests that generate temporary knowledge files."""

    global _CHUNKS  # noqa: PLW0603
    _CHUNKS = _load_chunks()


def search(
    query: str,
    *,
    section_id: str | None = None,
    top_k: int = 3,
) -> list[dict[str, Any]]:
    """Return top local chunks using a small deterministic keyword score."""

    safe_top_k = max(1, min(int(top_k or 3), 5))
    candidates = _CHUNKS
    if section_id:
        scoped = [c for c in candidates if c.get("sectionId") == section_id]
        if scoped:
            candidates = scoped
    hits = sorted(candidates, key=lambda item: -_score(query, item))[:safe_top_k]
    return [{**h, "score": _score(query, h)} for h in hits]


def prompt_context(
    *,
    section_id: str,
    question_prompt: str,
    top_k: int = 3,
) -> str:
    hits = search(question_prompt, section_id=section_id, top_k=top_k)
    logger.info("[lecture-agent] knowledge_hits=%d section=%s", len(hits), section_id)
    if not hits:
        return ""
    lines = ["【课本知识片段】"]
    for idx, hit in enumerate(hits, start=1):
        title = hit.get("title") or hit.get("id")
        text = hit.get("text") or ""
        lines.append(f"{idx}. {title}: {text}")
    return "\n".join(lines)


def _score(query: str, item: dict[str, Any]) -> float:
    haystack = (
        str(item.get("title") or "")
        + str(item.get("text") or "")
        + "".join(str(k) for k in item.get("keywords") or [])
    ).lower()
    q = str(query or "").lower()
    if not haystack:
        return 0.0
    char_score = sum(1 for ch in set(q) if ch and ch in haystack)
    keyword_score = sum(4 for k in item.get("keywords") or [] if str(k).lower() in q)
    return round((char_score + keyword_score) / max(1.0, math.sqrt(len(haystack))), 4)
