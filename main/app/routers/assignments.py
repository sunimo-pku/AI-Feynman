"""家长布置作业 + 学生待办 API。"""

from __future__ import annotations

import base64
import logging
import uuid
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import ParentAssignment, User, get_db, linked_child_profile
from app.middleware.auth import require_parent_user, require_student_user
from app.services.assignment_service import (
    assignment_to_public,
    build_assignment_report,
    new_custom_question_id,
    refresh_assignment_status,
    resolve_catalog_question,
    section_label,
)
from app.services.qwen_vision import recognize_question_image

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Assignments"])


# ---------------------------------------------------------------------------
# IO
# ---------------------------------------------------------------------------


class CatalogAssignmentCreate(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    difficulty: int = Field(1, ge=1, le=3)
    title: str = Field("", max_length=128)
    note: str = Field("", max_length=1000)
    due_at: datetime = Field(..., alias="dueAt")

    model_config = {"populate_by_name": True}


class CustomAssignmentCreate(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_prompt: str = Field(..., alias="questionPrompt", min_length=4, max_length=2000)
    title: str = Field("", max_length=128)
    note: str = Field("", max_length=1000)
    due_at: datetime = Field(..., alias="dueAt")
    knowledge_tags: list[str] = Field(default_factory=list, alias="knowledgeTags")

    model_config = {"populate_by_name": True}


class AssignmentCreateRequest(BaseModel):
    source_type: Literal["catalog", "custom"] = Field(..., alias="sourceType")
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    difficulty: int = Field(1, ge=1, le=3)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    title: str = Field("", max_length=128)
    note: str = Field("", max_length=1000)
    due_at: datetime = Field(..., alias="dueAt")
    knowledge_tags: list[str] = Field(default_factory=list, alias="knowledgeTags")

    model_config = {"populate_by_name": True}


def _require_child(db: Session, user: User):
    profile = linked_child_profile(db, user)
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No child linked to this parent account.",
        )
    return profile


def _normalize_utc(dt: datetime) -> datetime:
    if dt.tzinfo is not None:
        return dt.replace(tzinfo=None)
    return dt


def _validate_due_at(due_at: datetime) -> None:
    if _normalize_utc(due_at) <= datetime.utcnow():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="dueAt must be in the future.",
        )


def _create_assignment_row(
    *,
    db: Session,
    parent_user: User,
    student_id: int,
    req: AssignmentCreateRequest,
) -> ParentAssignment:
    _validate_due_at(req.due_at)
    sid = req.section_id.strip()
    label = section_label(sid)

    if req.source_type == "catalog":
        try:
            question = resolve_catalog_question(sid, req.difficulty)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        question_id = str(question.get("questionId") or "")
        question_prompt = str(question.get("prompt") or "")
        difficulty = int(question.get("difficulty") or req.difficulty)
    else:
        prompt = req.question_prompt.strip()
        if len(prompt) < 4:
            raise HTTPException(status_code=400, detail="questionPrompt is required for custom assignments.")
        question_id = new_custom_question_id()
        question_prompt = prompt
        difficulty = req.difficulty

    title = req.title.strip() or (
        f"{label} · {'基础' if difficulty == 1 else '巩固' if difficulty == 2 else '挑战'}题"
        if req.source_type == "catalog"
        else f"家长自定义 · {label}"
    )

    row = ParentAssignment(
        id=str(uuid.uuid4()),
        student_id=student_id,
        parent_user_id=parent_user.id,
        source_type=req.source_type,
        section_id=sid,
        section_label=label,
        question_id=question_id,
        question_prompt=question_prompt,
        difficulty=difficulty,
        title=title,
        note=req.note.strip(),
        due_at=req.due_at,
        status="pending",
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    refresh_assignment_status(row)
    db.commit()
    logger.info(
        "[assignment] created id=%s parent=%s student=%s source=%s",
        row.id,
        parent_user.username,
        student_id,
        req.source_type,
    )
    return row


# ---------------------------------------------------------------------------
# 家长端
# ---------------------------------------------------------------------------


@router.post(
    "/parent/assignments/recognize-image",
    summary="家长上传题目图片识题（用于自定义作业）",
)
async def parent_recognize_assignment_image(
    file: UploadFile = File(...),
    user: User = Depends(require_parent_user),
):
    _ = user
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty image.")
    image_base64 = base64.b64encode(data).decode("ascii")
    vision = recognize_question_image(
        image_base64=image_base64,
        mime_type=file.content_type or "image/jpeg",
    )
    if vision.get("error"):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Question vision failed: {vision.get('error')}",
        )
    return vision


@router.post(
    "/parent/assignments",
    summary="家长布置作业（题库小节+难度 或 自定义题面）",
)
async def create_parent_assignment(
    req: AssignmentCreateRequest,
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = _require_child(db, user)
    row = _create_assignment_row(
        db=db,
        parent_user=user,
        student_id=profile.id,
        req=req,
    )
    return assignment_to_public(row)


@router.get("/parent/assignments", summary="家长查看已布置作业列表")
async def list_parent_assignments(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
    status_filter: str | None = Query(None, alias="status"),
    limit: int = Query(50, ge=1, le=100),
):
    profile = _require_child(db, user)
    q = (
        db.query(ParentAssignment)
        .filter(ParentAssignment.student_id == profile.id)
        .order_by(ParentAssignment.created_at.desc())
    )
    if status_filter:
        q = q.filter(ParentAssignment.status == status_filter)
    rows = q.limit(limit).all()
    now = datetime.utcnow()
    items = []
    for row in rows:
        refresh_assignment_status(row, now=now)
        items.append(assignment_to_public(row))
    db.commit()
    pending = sum(1 for i in items if i["status"] in ("pending", "in_progress", "overdue"))
    completed = sum(1 for i in items if i["status"] == "completed")
    return {
        "assignments": items,
        "pendingCount": pending,
        "completedCount": completed,
    }


@router.get(
    "/parent/assignments/{assignment_id}",
    summary="家长查看单条作业详情",
)
async def get_parent_assignment(
    assignment_id: str,
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = _require_child(db, user)
    row = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.id == assignment_id,
            ParentAssignment.student_id == profile.id,
        )
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Assignment not found.")
    refresh_assignment_status(row)
    db.commit()
    return assignment_to_public(row, include_report=True, db=db)


@router.get(
    "/parent/assignments/{assignment_id}/report",
    summary="家长查看作业完成报告",
)
async def parent_assignment_report(
    assignment_id: str,
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = _require_child(db, user)
    row = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.id == assignment_id,
            ParentAssignment.student_id == profile.id,
        )
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Assignment not found.")
    refresh_assignment_status(row)
    db.commit()
    if row.status != "completed":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Assignment is not completed yet.",
        )
    return build_assignment_report(db, row)


@router.delete(
    "/parent/assignments/{assignment_id}",
    summary="撤销未完成的作业",
)
async def delete_parent_assignment(
    assignment_id: str,
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = _require_child(db, user)
    row = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.id == assignment_id,
            ParentAssignment.student_id == profile.id,
        )
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Assignment not found.")
    if row.completed_at is not None:
        raise HTTPException(status_code=400, detail="Completed assignments cannot be deleted.")
    db.delete(row)
    db.commit()
    return {"ok": True}


# ---------------------------------------------------------------------------
# 学生端
# ---------------------------------------------------------------------------


@router.get("/learning/assignments", summary="学生待办作业列表")
async def list_student_assignments(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    from app.db import ensure_student_profile

    profile = ensure_student_profile(db, user)
    rows = (
        db.query(ParentAssignment)
        .filter(ParentAssignment.student_id == profile.id)
        .order_by(ParentAssignment.due_at.asc())
        .limit(50)
        .all()
    )
    now = datetime.utcnow()
    active: list[dict] = []
    completed: list[dict] = []
    for row in rows:
        refresh_assignment_status(row, now=now)
        item = assignment_to_public(row)
        if row.status == "completed":
            completed.append(item)
        else:
            active.append(item)
    db.commit()
    return {
        "active": active,
        "completed": completed[:10],
        "pendingCount": len(active),
    }


@router.post("/learning/assignments/{assignment_id}/open", summary="学生打开作业")
async def open_student_assignment(
    assignment_id: str,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    from app.db import ensure_student_profile

    profile = ensure_student_profile(db, user)
    row = (
        db.query(ParentAssignment)
        .filter(
            ParentAssignment.id == assignment_id,
            ParentAssignment.student_id == profile.id,
        )
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Assignment not found.")
    if row.completed_at is None and row.opened_at is None:
        row.opened_at = datetime.utcnow()
    refresh_assignment_status(row)
    db.commit()
    db.refresh(row)
    return assignment_to_public(row)
