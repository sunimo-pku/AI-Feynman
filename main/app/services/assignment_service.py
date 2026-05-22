"""家长布置作业：题库解析、状态计算、完成核销。"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from app.db import (
    LectureReview,
    LectureSessionRecord,
    ParentAssignment,
    dump_json,
    load_json,
)

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_QUESTIONS_FILE = _PROJECT_ROOT / "data" / "questions" / "pep-junior-math-questions.json"
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"

_SECTION_LABELS: dict[str, str] | None = None


def _load_section_labels() -> dict[str, str]:
    global _SECTION_LABELS  # noqa: PLW0603
    if _SECTION_LABELS is not None:
        return _SECTION_LABELS
    labels: dict[str, str] = {}
    try:
        payload = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
        for book in payload.get("books", []):
            for chapter in book.get("chapters", []):
                for section in chapter.get("sections", []):
                    sid = str(section.get("id") or "")
                    label = str(section.get("label") or section.get("title") or "")
                    if sid and label:
                        labels[sid] = label
    except Exception as exc:  # noqa: BLE001
        logger.warning("assignment_service: curriculum labels failed: %s", exc)
    _SECTION_LABELS = labels
    return labels


def section_label(section_id: str) -> str:
    return _load_section_labels().get(section_id, section_id)


def _load_questions_for_section(section_id: str) -> list[dict[str, Any]]:
    try:
        raw = json.loads(_QUESTIONS_FILE.read_text(encoding="utf-8"))
        items = raw.get("questions") if isinstance(raw, dict) else []
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"Question bank unavailable: {exc}") from exc
    if not isinstance(items, list):
        return []
    return [
        item
        for item in items
        if isinstance(item, dict) and item.get("sectionId") == section_id
    ]


def resolve_catalog_question(section_id: str, difficulty: int) -> dict[str, Any]:
    """按小节 + 难度解析 seed 题库中的一道题。"""

    questions = _load_questions_for_section(section_id)
    if not questions:
        raise ValueError(f"No questions for section {section_id}")
    safe_diff = max(1, min(3, int(difficulty or 1)))
    matched = next((q for q in questions if int(q.get("difficulty") or 1) == safe_diff), None)
    if matched is None:
        idx = min(safe_diff - 1, len(questions) - 1)
        matched = questions[idx]
    return matched


def new_custom_question_id() -> str:
    return f"q-parent-{uuid.uuid4().hex[:12]}"


def compute_status(row: ParentAssignment, *, now: datetime | None = None) -> str:
    now = now or datetime.utcnow()
    if row.completed_at is not None:
        return "completed"
    due = row.due_at
    if due is not None and now > _normalize_utc(due):
        return "overdue"
    if row.opened_at is not None:
        return "in_progress"
    return "pending"


def _normalize_utc(dt: datetime) -> datetime:
    if dt.tzinfo is not None:
        return dt.replace(tzinfo=None)
    return dt


def refresh_assignment_status(row: ParentAssignment, *, now: datetime | None = None) -> str:
    status = compute_status(row, now=now)
    row.status = status
    return status


def mark_assignments_completed(
    db: Session,
    *,
    student_id: int,
    section_id: str,
    question_id: str,
    review_client_id: str | None = None,
    summary: str = "",
    agent_highlights: list[str] | None = None,
    caution_points: list[str] | None = None,
    mastery_delta: int = 0,
    round_count: int = 0,
) -> int:
    """讲题完成后核销匹配的待办作业。返回本次核销条数。"""

    rows = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.student_id == student_id,
            ParentAssignment.question_id == question_id,
            ParentAssignment.status.in_(("pending", "in_progress", "overdue")),
        )
        .all()
    )
    if not rows:
        return 0

    now = datetime.utcnow()
    count = 0
    for row in rows:
        if row.section_id != section_id:
            continue
        row.status = "completed"
        row.completed_at = now
        if review_client_id:
            row.review_client_id = review_client_id
        if summary:
            row.completion_summary = summary
        row.completion_mastery_delta = int(mastery_delta or 0)
        row.completion_round_count = max(int(round_count or 0), 1)
        row.report_json = dump_json(
            {
                "summary": summary,
                "agentHighlights": agent_highlights or [],
                "cautionPoints": caution_points or [],
                "masteryDelta": mastery_delta,
                "roundCount": round_count,
                "completedAt": now.isoformat(),
            }
        )
        count += 1
        logger.info(
            "[assignment] completed id=%s student=%s question=%s",
            row.id,
            student_id,
            question_id,
        )
    return count


def build_assignment_report(db: Session, row: ParentAssignment) -> dict[str, Any]:
    """组装家长端作业完成报告。"""

    refresh_assignment_status(row)
    report_snapshot = load_json(row.report_json, {}) or {}
    review: LectureReview | None = None
    if row.review_client_id:
        review = (
            db.query(LectureReview)
            .filter(LectureReview.client_id == row.review_client_id)
            .first()
        )
    session: LectureSessionRecord | None = None
    if review is not None:
        session = (
            db.query(LectureSessionRecord)
            .filter(
                LectureSessionRecord.student_id == row.student_id,
                LectureSessionRecord.question_id == row.question_id,
                LectureSessionRecord.status == "completed",
            )
            .order_by(LectureSessionRecord.completed_at.desc())
            .first()
        )

    summary = row.completion_summary or (review.summary if review else "") or report_snapshot.get("summary", "")
    highlights = (
        load_json(review.agent_highlights_json, []) if review else report_snapshot.get("agentHighlights", [])
    )
    cautions = (
        load_json(review.caution_points_json, []) if review else report_snapshot.get("cautionPoints", [])
    )
    turns = load_json(session.turns_json, []) if session else []
    steps = load_json(session.steps_json, []) if session else []

    on_time = True
    if row.due_at and row.completed_at:
        on_time = _normalize_utc(row.completed_at) <= _normalize_utc(row.due_at)

    return {
        "assignmentId": row.id,
        "title": row.title,
        "note": row.note,
        "sourceType": row.source_type,
        "sectionId": row.section_id,
        "sectionLabel": row.section_label or section_label(row.section_id),
        "questionId": row.question_id,
        "questionPrompt": row.question_prompt,
        "difficulty": int(row.difficulty or 1),
        "dueAt": row.due_at,
        "status": row.status,
        "createdAt": row.created_at,
        "openedAt": row.opened_at,
        "completedAt": row.completed_at,
        "onTime": on_time,
        "summary": summary,
        "agentHighlights": highlights,
        "cautionPoints": cautions,
        "masteryDelta": int(row.completion_mastery_delta or 0),
        "roundCount": int(row.completion_round_count or 0),
        "reviewClientId": row.review_client_id,
        "transcriptText": session.transcript_text if session else "",
        "turns": turns,
        "steps": steps,
        "customImage": load_json(row.custom_image_json, {}),
    }


def assignment_to_public(row: ParentAssignment, *, include_report: bool = False, db: Session | None = None) -> dict[str, Any]:
    refresh_assignment_status(row)
    payload: dict[str, Any] = {
        "assignmentId": row.id,
        "title": row.title,
        "note": row.note,
        "sourceType": row.source_type,
        "sectionId": row.section_id,
        "sectionLabel": row.section_label or section_label(row.section_id),
        "questionId": row.question_id,
        "questionPrompt": row.question_prompt,
        "difficulty": int(row.difficulty or 1),
        "dueAt": row.due_at,
        "status": row.status,
        "createdAt": row.created_at,
        "openedAt": row.opened_at,
        "completedAt": row.completed_at,
        "completionSummary": row.completion_summary or "",
    }
    if include_report and db is not None:
        payload["report"] = build_assignment_report(db, row)
    return payload
