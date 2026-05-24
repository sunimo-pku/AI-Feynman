"""题目收藏与家长反馈（学生端写入 / 家长端只读）。"""

from __future__ import annotations

import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    QuestionFavorite,
    QuestionFeedback,
    StudentProfile,
    User,
    ensure_student_profile,
    get_db,
    linked_child_profile,
)
from app.middleware.auth import require_parent_user, require_student_user

logger = logging.getLogger(__name__)

student_router = APIRouter(prefix="/learning", tags=["Learning"])
parent_router = APIRouter(prefix="/parent", tags=["Parent"])


class FavoriteItemOut(BaseModel):
    question_id: str = Field(..., serialization_alias="questionId")
    section_id: str = Field(..., serialization_alias="sectionId")
    question_prompt: str = Field("", serialization_alias="questionPrompt")
    difficulty: int = 1
    created_at: datetime = Field(..., serialization_alias="createdAt")

    model_config = {"populate_by_name": True}


class FavoritesListOut(BaseModel):
    favorites: list[FavoriteItemOut] = Field(default_factory=list)

    model_config = {"populate_by_name": True}


class FavoriteUpsertRequest(BaseModel):
    question_id: str = Field(..., alias="questionId", min_length=1, max_length=64)
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    difficulty: int = Field(1, ge=1, le=3)
    favorited: bool = True

    model_config = {"populate_by_name": True}


class QuestionFeedbackRequest(BaseModel):
    question_id: str = Field(..., alias="questionId", min_length=1, max_length=64)
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    note: str = Field("", max_length=500)
    difficulty: int = Field(1, ge=1, le=3)

    model_config = {"populate_by_name": True}


class QuestionFeedbackOut(BaseModel):
    id: int
    question_id: str = Field(..., serialization_alias="questionId")
    section_id: str = Field(..., serialization_alias="sectionId")
    question_prompt: str = Field("", serialization_alias="questionPrompt")
    note: str = ""
    difficulty: int = 1
    created_at: datetime = Field(..., serialization_alias="createdAt")

    model_config = {"populate_by_name": True}


class ParentQuestionFeedbackOut(QuestionFeedbackOut):
    student_name: str = Field("", serialization_alias="studentName")
    section_label: str = Field("", serialization_alias="sectionLabel")

    model_config = {"populate_by_name": True}


def _favorite_to_out(row: QuestionFavorite) -> FavoriteItemOut:
    return FavoriteItemOut(
        question_id=row.question_id,
        section_id=row.section_id,
        question_prompt=row.question_prompt or "",
        difficulty=int(row.difficulty or 1),
        created_at=row.created_at or datetime.utcnow(),
    )


def _feedback_to_out(row: QuestionFeedback) -> QuestionFeedbackOut:
    return QuestionFeedbackOut(
        id=int(row.id),
        question_id=row.question_id,
        section_id=row.section_id,
        question_prompt=row.question_prompt or "",
        note=row.note or "",
        difficulty=int(row.difficulty or 1),
        created_at=row.created_at or datetime.utcnow(),
    )


@student_router.get(
    "/favorites",
    response_model=FavoritesListOut,
    response_model_by_alias=True,
)
async def list_favorites(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> FavoritesListOut:
    profile = ensure_student_profile(db, user)
    rows = (
        db.query(QuestionFavorite)
        .filter(QuestionFavorite.student_id == profile.id)
        .order_by(QuestionFavorite.created_at.desc())
        .limit(200)
        .all()
    )
    return FavoritesListOut(favorites=[_favorite_to_out(r) for r in rows])


@student_router.put(
    "/favorites",
    response_model=FavoriteItemOut,
    response_model_by_alias=True,
)
async def upsert_favorite(
    req: FavoriteUpsertRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> FavoriteItemOut:
    profile = ensure_student_profile(db, user)
    if not req.favorited:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Use DELETE /learning/favorites/{questionId} to unfavorite.",
        )
    existing = (
        db.query(QuestionFavorite)
        .filter(
            QuestionFavorite.student_id == profile.id,
            QuestionFavorite.question_id == req.question_id,
        )
        .first()
    )
    if existing is None:
        row = QuestionFavorite(
            student_id=profile.id,
            question_id=req.question_id,
            section_id=req.section_id,
            question_prompt=req.question_prompt,
            difficulty=req.difficulty,
        )
        db.add(row)
    else:
        existing.section_id = req.section_id
        existing.question_prompt = req.question_prompt
        existing.difficulty = req.difficulty
        row = existing
    try:
        db.commit()
        db.refresh(row)
    except Exception as e:  # noqa: BLE001
        db.rollback()
        logger.exception("[learning] favorite upsert failed: %s", e)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to save favorite.",
        ) from e
    return _favorite_to_out(row)


@student_router.delete("/favorites/{question_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_favorite(
    question_id: str,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> None:
    profile = ensure_student_profile(db, user)
    row = (
        db.query(QuestionFavorite)
        .filter(
            QuestionFavorite.student_id == profile.id,
            QuestionFavorite.question_id == question_id,
        )
        .first()
    )
    if row is not None:
        db.delete(row)
        db.commit()


@student_router.post(
    "/question-feedback",
    response_model=QuestionFeedbackOut,
    response_model_by_alias=True,
    status_code=status.HTTP_201_CREATED,
)
async def submit_question_feedback(
    req: QuestionFeedbackRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> QuestionFeedbackOut:
    profile = ensure_student_profile(db, user)
    note = (req.note or "").strip()
    row = QuestionFeedback(
        student_id=profile.id,
        question_id=req.question_id,
        section_id=req.section_id,
        question_prompt=req.question_prompt,
        note=note,
        difficulty=req.difficulty,
    )
    db.add(row)
    try:
        db.commit()
        db.refresh(row)
    except Exception as e:  # noqa: BLE001
        db.rollback()
        logger.exception("[learning] question feedback failed: %s", e)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to save question feedback.",
        ) from e
    logger.info(
        "[learning] question-feedback user=%s question=%s note_len=%d",
        user.username,
        req.question_id,
        len(note),
    )
    return _feedback_to_out(row)


def _require_linked_child(db: Session, user: User) -> StudentProfile:
    profile = linked_child_profile(db, user)
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No linked child profile.",
        )
    return profile


def _section_label(section_id: str) -> str:
    from app.routers.parent import _SECTION_LABEL

    return _SECTION_LABEL.get(section_id, section_id)


@parent_router.get(
    "/question-feedback",
    response_model=list[ParentQuestionFeedbackOut],
    response_model_by_alias=True,
)
async def parent_list_question_feedback(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
    limit: int = Query(30, ge=1, le=100),
) -> list[ParentQuestionFeedbackOut]:
    profile = _require_linked_child(db, user)
    rows = (
        db.query(QuestionFeedback)
        .filter(QuestionFeedback.student_id == profile.id)
        .order_by(QuestionFeedback.created_at.desc())
        .limit(limit)
        .all()
    )
    student_name = profile.display_name or user.username
    return [
        ParentQuestionFeedbackOut(
            id=int(r.id),
            question_id=r.question_id,
            section_id=r.section_id,
            question_prompt=r.question_prompt or "",
            note=r.note or "",
            difficulty=int(r.difficulty or 1),
            created_at=r.created_at or datetime.utcnow(),
            student_name=student_name,
            section_label=_section_label(r.section_id),
        )
        for r in rows
    ]
