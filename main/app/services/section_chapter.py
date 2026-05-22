"""小节 id ↔ 大章 id（pep-g8-down-s16-3 → pep-g8-down-ch16）。"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

from app.services.section_grade import section_grade_label

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"

_SECTION_TO_CHAPTER = re.compile(r"^(pep-g\d-(?:up|down|sprint)-)s(\d+)-\d+$")


def chapter_id_from_section_id(section_id: str) -> str | None:
    match = _SECTION_TO_CHAPTER.match((section_id or "").strip())
    if not match:
        return None
    return f"{match.group(1)}ch{match.group(2)}"


def section_belongs_to_chapter(section_id: str, chapter_id: str) -> bool:
    derived = chapter_id_from_section_id(section_id)
    if not derived:
        return False
    return derived == (chapter_id or "").strip()


def chapter_in_student_grade(chapter_id: str, grade: str) -> bool:
    """大章 id 与 section 共用 pep-gN- 前缀，复用年级映射。"""
    label = section_grade_label(chapter_id)
    if label is None:
        return False
    return label == (grade or "").strip()


def resolve_leaderboard_chapter_id(raw_id: str) -> str | None:
    """接受 chapterId 或旧 sectionId，统一成大章 id。"""
    trimmed = (raw_id or "").strip()
    if not trimmed:
        return None
    if "-ch" in trimmed:
        return trimmed
    return chapter_id_from_section_id(trimmed)


@lru_cache(maxsize=1)
def load_chapter_labels() -> dict[str, str]:
    labels: dict[str, str] = {}
    try:
        payload = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
        for book in payload.get("books", []):
            for chapter in book.get("chapters", []):
                cid = str(chapter.get("id") or "").strip()
                label = str(chapter.get("label") or chapter.get("title") or "").strip()
                if cid and label:
                    labels[cid] = label
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    return labels


def chapter_label(chapter_id: str) -> str:
    return load_chapter_labels().get(chapter_id, chapter_id)
