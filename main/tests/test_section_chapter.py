from __future__ import annotations

from app.services.section_chapter import (
    chapter_id_from_section_id,
    chapter_in_student_grade,
    resolve_leaderboard_chapter_id,
    section_belongs_to_chapter,
)


def test_chapter_id_from_section_id() -> None:
    assert chapter_id_from_section_id("pep-g8-down-s16-3") == "pep-g8-down-ch16"
    assert chapter_id_from_section_id("pep-g7-up-s3-2") == "pep-g7-up-ch3"
    assert chapter_id_from_section_id("invalid") is None


def test_section_belongs_to_chapter() -> None:
    assert section_belongs_to_chapter("pep-g8-down-s16-1", "pep-g8-down-ch16")
    assert not section_belongs_to_chapter("pep-g8-down-s16-1", "pep-g8-down-ch19")


def test_resolve_leaderboard_chapter_id() -> None:
    assert resolve_leaderboard_chapter_id("pep-g8-down-ch16") == "pep-g8-down-ch16"
    assert resolve_leaderboard_chapter_id("pep-g8-down-s16-3") == "pep-g8-down-ch16"


def test_chapter_in_student_grade() -> None:
    assert chapter_in_student_grade("pep-g8-down-ch16", "八年级")
    assert not chapter_in_student_grade("pep-g7-down-ch9", "八年级")
