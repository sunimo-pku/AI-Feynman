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
    LearningProgress,
    LectureReview,
    LectureSessionRecord,
    ParentAssignment,
    StudentProfile,
    dump_json,
    load_json,
)
from app.services.learning_profile import (
    build_learning_profile,
    profile_reason_for_mistake,
    profile_reason_for_section,
)
from app.services.section_grade import section_in_student_grade

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_QUESTIONS_FILE = _PROJECT_ROOT / "data" / "questions" / "pep-junior-math-questions.json"
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"

_SECTION_LABELS: dict[str, str] | None = None
_QUESTION_BANK: list[dict[str, Any]] | None = None

_SECTION_WEAK_REASON: dict[str, str] = {
    "pep-g8-down-s16-1": "取值范围条件容易写漏",
    "pep-g8-down-s16-2": "公式法则前提条件不稳定",
    "pep-g8-down-s16-3": "合并运算时系数符号易错",
}

_DIFFICULTY_LABEL = {1: "基础", 2: "巩固", 3: "挑战"}


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


def _load_question_bank() -> list[dict[str, Any]]:
    global _QUESTION_BANK  # noqa: PLW0603
    if _QUESTION_BANK is not None:
        return _QUESTION_BANK
    try:
        raw = json.loads(_QUESTIONS_FILE.read_text(encoding="utf-8"))
        items = raw.get("questions") if isinstance(raw, dict) else []
    except Exception as exc:  # noqa: BLE001
        logger.warning("assignment_service: question bank failed: %s", exc)
        _QUESTION_BANK = []
        return _QUESTION_BANK
    _QUESTION_BANK = [item for item in items if isinstance(item, dict)]
    return _QUESTION_BANK


def _load_questions_for_section(section_id: str) -> list[dict[str, Any]]:
    return [
        item
        for item in _load_question_bank()
        if item.get("sectionId") == section_id
    ]


def resolve_question_by_id(question_id: str) -> dict[str, Any]:
    qid = (question_id or "").strip()
    if not qid:
        raise ValueError("questionId is required")
    matched = next(
        (q for q in _load_question_bank() if str(q.get("questionId") or "") == qid),
        None,
    )
    if matched is None:
        raise ValueError(f"Unknown questionId: {qid}")
    return matched


def _difficulty_for_mastery(mastery_score: int) -> int:
    if mastery_score < 30:
        return 1
    if mastery_score < 60:
        return 2
    return 2


def _question_to_recommendation_payload(
    question: dict[str, Any],
    *,
    reason: str,
    reason_type: str,
    mastery_score: int | None = None,
) -> dict[str, Any]:
    sid = str(question.get("sectionId") or "")
    diff = int(question.get("difficulty") or 1)
    return {
        "reason": reason,
        "reasonType": reason_type,
        "sectionId": sid,
        "sectionLabel": section_label(sid),
        "questionId": str(question.get("questionId") or ""),
        "questionPrompt": str(question.get("prompt") or ""),
        "difficulty": diff,
        "difficultyLabel": _DIFFICULTY_LABEL.get(diff, "基础"),
        "knowledgePointId": str(question.get("knowledgePointId") or ""),
        "knowledgePointLabel": str(question.get("knowledgePointLabel") or ""),
        "masteryScore": mastery_score,
    }


def build_assignment_recommendations(
    db: Session,
    *,
    student_id: int,
    student_grade: str = "八年级",
    limit: int = 6,
) -> list[dict[str, Any]]:
    """根据弱项小节、易错回顾与未完成讲题，推荐可布置的题库题目。"""

    limit = max(1, min(12, int(limit or 6)))

    progress_rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == student_id)
        .all()
    )
    progress_by_section = {row.section_id: row for row in progress_rows}

    pending_rows = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.student_id == student_id,
            ParentAssignment.status.in_(("pending", "in_progress", "overdue")),
        )
        .all()
    )
    pending_question_ids = {
        str(row.question_id or "")
        for row in pending_rows
        if row.question_id
    }

    review_rows = (
        db.query(LectureReview)
        .filter(LectureReview.student_id == student_id)
        .order_by(LectureReview.created_at.desc())
        .limit(30)
        .all()
    )

    incomplete_sessions = (
        db.query(LectureSessionRecord)
        .filter(
            LectureSessionRecord.student_id == student_id,
            LectureSessionRecord.status != "completed",
        )
        .order_by(LectureSessionRecord.started_at.desc())
        .limit(12)
        .all()
    )

    scored: list[tuple[int, dict[str, Any]]] = []
    seen_question_ids: set[str] = set()
    grade = (student_grade or "八年级").strip() or "八年级"

    student_profile = (
        db.query(StudentProfile).filter(StudentProfile.id == student_id).first()
    )
    learning_profile = (
        build_learning_profile(db, student_profile) if student_profile else None
    )

    def _try_add(priority: int, payload: dict[str, Any]) -> None:
        qid = str(payload.get("questionId") or "")
        sid = str(payload.get("sectionId") or "")
        if (
            not qid
            or qid in seen_question_ids
            or qid in pending_question_ids
            or not section_in_student_grade(sid, grade)
        ):
            return
        seen_question_ids.add(qid)
        scored.append((priority, payload))

    for idx, review in enumerate(review_rows):
        cautions = list(load_json(review.caution_points_json, []) or [])
        if not cautions:
            continue
        try:
            question = resolve_question_by_id(review.question_id)
        except ValueError:
            question = {
                "questionId": review.question_id,
                "sectionId": review.section_id,
                "prompt": review.question_prompt or "",
                "difficulty": int(review.difficulty or 1),
            }
        caution = str(cautions[0]).strip()
        if len(caution) > 48:
            caution = f"{caution[:48]}…"
        progress = progress_by_section.get(review.section_id)
        mastery = int(progress.mastery_score or 0) if progress else None
        if learning_profile is not None:
            reason = profile_reason_for_mistake(
                learning_profile,
                section_id=review.section_id,
                caution=caution,
            )
        else:
            reason = f"易错回顾：{caution}"
        _try_add(
            300 - idx,
            _question_to_recommendation_payload(
                question,
                reason=reason,
                reason_type="mistake_review",
                mastery_score=mastery,
            ),
        )

    practiced = [p for p in progress_rows if int(p.completed_rounds or 0) > 0]
    weak = sorted(
        [p for p in practiced if int(p.mastery_score or 0) < 60],
        key=lambda row: int(row.mastery_score or 0),
    )
    caution_sections = {
        row.section_id
        for row in review_rows
        if load_json(row.caution_points_json, [])
    }
    for row in weak:
        if row.section_id in caution_sections:
            continue
        score = int(row.mastery_score or 0)
        diff = _difficulty_for_mastery(score)
        try:
            question = resolve_catalog_question(row.section_id, diff)
        except ValueError:
            continue
        reason = None
        if learning_profile is not None:
            reason = profile_reason_for_section(learning_profile, row.section_id)
        if not reason:
            reason = _SECTION_WEAK_REASON.get(row.section_id) or f"掌握度 {score}/100，建议巩固"
        _try_add(
            120 - score,
            _question_to_recommendation_payload(
                question,
                reason=reason,
                reason_type="weak_section",
                mastery_score=score,
            ),
        )

    for idx, session in enumerate(incomplete_sessions):
        if not session.question_id:
            continue
        try:
            question = resolve_question_by_id(session.question_id)
        except ValueError:
            question = {
                "questionId": session.question_id,
                "sectionId": session.section_id,
                "prompt": "",
                "difficulty": 1,
            }
        progress = progress_by_section.get(session.section_id)
        mastery = int(progress.mastery_score or 0) if progress else None
        _try_add(
            80 - idx,
            _question_to_recommendation_payload(
                question,
                reason="上次讲题未完成，建议再练一遍",
                reason_type="incomplete_session",
                mastery_score=mastery,
            ),
        )

    if len(scored) < limit:
        unpracticed = sorted(
            [p for p in progress_rows if int(p.completed_rounds or 0) == 0],
            key=lambda row: row.last_practiced_at or datetime.min,
        )
        for row in unpracticed[: max(0, limit - len(scored))]:
            try:
                question = resolve_catalog_question(row.section_id, 1)
            except ValueError:
                continue
            _try_add(
                40,
                _question_to_recommendation_payload(
                    question,
                    reason="本节还没练过，先从基础题开始",
                    reason_type="unpracticed_section",
                    mastery_score=0,
                ),
            )

    scored.sort(key=lambda item: -item[0])

    if not scored:
        starter_sections: list[str] = []
        for question in _load_question_bank():
            sid = str(question.get("sectionId") or "")
            if sid in starter_sections or not section_in_student_grade(sid, grade):
                continue
            starter_sections.append(sid)
            if len(starter_sections) >= limit:
                break
        for sid in starter_sections:
            try:
                question = resolve_catalog_question(sid, 1)
            except ValueError:
                continue
            _try_add(
                10,
                _question_to_recommendation_payload(
                    question,
                    reason="孩子还没有讲题记录，可先布置基础练手题",
                    reason_type="starter",
                    mastery_score=0,
                ),
            )

    scored.sort(key=lambda item: -item[0])
    return [payload for _, payload in scored[:limit]]


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
