"""小节 id ↔ 年级标签（pep-g7-* → 七年级）。"""

from __future__ import annotations

import re

_GRADE_BY_NUM = {"7": "七年级", "8": "八年级", "9": "九年级"}


def section_grade_label(section_id: str) -> str | None:
    match = re.match(r"^pep-g(\d)-", (section_id or "").strip())
    if not match:
        return None
    return _GRADE_BY_NUM.get(match.group(1))


def section_in_student_grade(section_id: str, grade: str) -> bool:
    label = section_grade_label(section_id)
    if label is None:
        return False
    return label == (grade or "").strip()
