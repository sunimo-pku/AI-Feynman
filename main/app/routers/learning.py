"""学习进度 / 回顾同步路由（第十轮）。

提供：
- `GET /learning/progress`：取登录学生的全部小节进度
- `POST /learning/progress/sync`：客户端上传本地 `SectionProgress` + `LectureReviewRecord` 做双向合并
- `GET /learning/reviews`：取登录学生的全部回顾记录

设计原则：
- 必须登录（401 显式抛出，不被通用 Exception handler 吞）；
- 字段一律 camelCase 出入，与 Flutter 端 JSON 一致；
- 合并策略：同 `section_id` 按 `(completedRounds, lastPracticedAt)` 取「更新者优先」；
- review 按 `clientId` 去重，重复上传 idempotent；
- 异常一律走 `HTTPException`，不要 `return {"error": ...}` 让前端误以为成功。
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureReview,
    StudentProfile,
    User,
    dump_json,
    ensure_student_profile,
    get_db,
    load_json,
)
from app.middleware.auth import require_student_user
from app.services.learning_profile import LearningProfileOut, build_learning_profile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/learning", tags=["Learning"])


# ---------------------------------------------------------------------------
# IO 模型
# ---------------------------------------------------------------------------


class ProgressItem(BaseModel):
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    completed_rounds: int = Field(0, alias="completedRounds", ge=0, le=10000)
    mastery_score: int = Field(0, alias="masteryScore", ge=0, le=100)
    last_practiced_at: datetime | None = Field(None, alias="lastPracticedAt")
    last_summary: str = Field("", alias="lastSummary", max_length=2000)

    model_config = {
        "populate_by_name": True,
    }


class ReviewItem(BaseModel):
    client_id: str = Field(..., alias="id", min_length=1, max_length=96)
    section_id: str = Field(..., alias="sectionId", min_length=1, max_length=64)
    question_id: str = Field(..., alias="questionId", min_length=1, max_length=64)
    question_prompt: str = Field("", alias="questionPrompt", max_length=2000)
    difficulty: int = Field(1, ge=1, le=3)
    tags: list[str] = Field(default_factory=list)
    completed_at: datetime = Field(..., alias="completedAt")
    summary: str = Field("", max_length=2000)
    agent_highlights: list[str] = Field(default_factory=list, alias="agentHighlights")
    caution_points: list[str] = Field(default_factory=list, alias="cautionPoints")

    model_config = {
        "populate_by_name": True,
    }


class SyncRequest(BaseModel):
    progress: list[ProgressItem] = Field(default_factory=list)
    reviews: list[ReviewItem] = Field(default_factory=list)
    mode: Literal["merge", "overwrite"] = "merge"

    model_config = {"populate_by_name": True}


class ProfilePatchRequest(BaseModel):
    display_name: str | None = Field(None, alias="displayName", max_length=64)
    grade: str | None = Field(None, max_length=32)
    school_name: str | None = Field(None, alias="schoolName", max_length=96)
    province: str | None = Field(None, max_length=32)
    city: str | None = Field(None, max_length=32)
    district: str | None = Field(None, max_length=32)
    equipped_title: str | None = Field(None, alias="equippedTitle", max_length=96)

    model_config = {"populate_by_name": True}


class ProfileOut(BaseModel):
    id: int
    display_name: str = Field("", serialization_alias="displayName")
    grade: str = ""
    school_name: str = Field("", serialization_alias="schoolName")
    province: str = ""
    city: str = ""
    district: str = ""
    equipped_title: str = Field("", serialization_alias="equippedTitle")

    model_config = {"populate_by_name": True}


class ProgressOut(BaseModel):
    section_id: str = Field(..., serialization_alias="sectionId")
    completed_rounds: int = Field(0, serialization_alias="completedRounds")
    mastery_score: int = Field(0, serialization_alias="masteryScore")
    last_practiced_at: datetime | None = Field(
        None, serialization_alias="lastPracticedAt"
    )
    last_summary: str = Field("", serialization_alias="lastSummary")

    model_config = {"populate_by_name": True}


class ReviewOut(BaseModel):
    client_id: str = Field(..., serialization_alias="id")
    section_id: str = Field(..., serialization_alias="sectionId")
    question_id: str = Field(..., serialization_alias="questionId")
    question_prompt: str = Field("", serialization_alias="questionPrompt")
    difficulty: int = 1
    tags: list[str] = Field(default_factory=list)
    completed_at: datetime = Field(..., serialization_alias="completedAt")
    summary: str = ""
    agent_highlights: list[str] = Field(
        default_factory=list, serialization_alias="agentHighlights"
    )
    caution_points: list[str] = Field(
        default_factory=list, serialization_alias="cautionPoints"
    )

    model_config = {"populate_by_name": True}


class SyncResponse(BaseModel):
    progress: list[ProgressOut]
    reviews: list[ReviewOut]
    accepted_progress: int = Field(0, serialization_alias="acceptedProgress")
    accepted_reviews: int = Field(0, serialization_alias="acceptedReviews")
    server_time: datetime = Field(
        default_factory=datetime.utcnow, serialization_alias="serverTime"
    )

    model_config = {"populate_by_name": True}


SyncStatus = Literal["merged", "kept_local", "kept_server"]


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------


def _progress_to_out(row: LearningProgress) -> ProgressOut:
    return ProgressOut(
        section_id=row.section_id,
        completed_rounds=int(row.completed_rounds or 0),
        mastery_score=int(row.mastery_score or 0),
        last_practiced_at=row.last_practiced_at,
        last_summary=row.last_summary or "",
    )


def _review_to_out(row: LectureReview) -> ReviewOut:
    return ReviewOut(
        client_id=row.client_id,
        section_id=row.section_id,
        question_id=row.question_id,
        question_prompt=row.question_prompt or "",
        difficulty=int(row.difficulty or 1),
        tags=list(load_json(row.tags_json, []) or []),
        completed_at=row.created_at,
        summary=row.summary or "",
        agent_highlights=list(load_json(row.agent_highlights_json, []) or []),
        caution_points=list(load_json(row.caution_points_json, []) or []),
    )


def _profile_to_out(profile: StudentProfile) -> ProfileOut:
    return ProfileOut(
        id=int(profile.id),
        display_name=profile.display_name or "",
        grade=profile.grade or "",
        school_name=getattr(profile, "school_name", "") or "",
        province=getattr(profile, "province", "") or "",
        city=getattr(profile, "city", "") or "",
        district=getattr(profile, "district", "") or "",
        equipped_title=getattr(profile, "equipped_title", "") or "",
    )


@router.get(
    "/progress",
    response_model=list[ProgressOut],
    response_model_by_alias=True,
)
async def list_progress(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> list[ProgressOut]:
    profile = ensure_student_profile(db, user)
    rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .order_by(LearningProgress.section_id.asc())
        .all()
    )
    return [_progress_to_out(r) for r in rows]


@router.get(
    "/reviews",
    response_model=list[ReviewOut],
    response_model_by_alias=True,
)
async def list_reviews(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
    section_id: str | None = Query(None, alias="sectionId", max_length=64),
    limit: int = Query(30, ge=1, le=100),
) -> list[ReviewOut]:
    profile = ensure_student_profile(db, user)
    q = db.query(LectureReview).filter(LectureReview.student_id == profile.id)
    if section_id:
        q = q.filter(LectureReview.section_id == section_id)
    rows = q.order_by(LectureReview.created_at.desc()).limit(limit).all()
    return [_review_to_out(r) for r in rows]


@router.get("/profile", response_model=ProfileOut, response_model_by_alias=True)
async def get_profile(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> ProfileOut:
    return _profile_to_out(ensure_student_profile(db, user))


@router.patch("/profile", response_model=ProfileOut, response_model_by_alias=True)
async def patch_profile(
    req: ProfilePatchRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> ProfileOut:
    profile = ensure_student_profile(db, user)
    for attr, value in (
        ("display_name", req.display_name),
        ("grade", req.grade),
        ("school_name", req.school_name),
        ("province", req.province),
        ("city", req.city),
        ("district", req.district),
        ("equipped_title", req.equipped_title),
    ):
        if value is not None:
            setattr(profile, attr, value.strip())
    db.commit()
    db.refresh(profile)
    logger.info("[learning] profile updated user=%s display=%s", user.username, profile.display_name)
    return _profile_to_out(profile)


@router.get(
    "/profile-insights",
    response_model=LearningProfileOut,
    response_model_by_alias=True,
    summary="学生端可解释长期学习画像",
)
async def learning_profile_insights(
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> LearningProfileOut:
    profile = ensure_student_profile(db, user)
    return build_learning_profile(db, profile)


@router.post(
    "/reviews",
    response_model=ReviewOut,
    response_model_by_alias=True,
    summary="单条讲题回顾 upsert",
)
async def upsert_review(
    req: ReviewItem,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> ReviewOut:
    profile = ensure_student_profile(db, user)
    existing = db.query(LectureReview).filter(LectureReview.client_id == req.client_id).first()
    if existing is None:
        existing = LectureReview(
            student_id=profile.id,
            client_id=req.client_id,
            section_id=req.section_id,
            question_id=req.question_id,
        )
        db.add(existing)
    elif existing.student_id != profile.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Review belongs to another student.")

    existing.section_id = req.section_id
    existing.question_id = req.question_id
    existing.question_prompt = req.question_prompt
    existing.difficulty = req.difficulty
    existing.tags_json = dump_json(req.tags)
    existing.summary = req.summary
    existing.agent_highlights_json = dump_json(req.agent_highlights)
    existing.caution_points_json = dump_json(req.caution_points)
    existing.created_at = req.completed_at
    db.commit()
    db.refresh(existing)
    from app.services.assignment_service import mark_assignments_completed

    mark_assignments_completed(
        db,
        student_id=profile.id,
        section_id=req.section_id,
        question_id=req.question_id,
        review_client_id=req.client_id,
        summary=req.summary,
        agent_highlights=req.agent_highlights,
        caution_points=req.caution_points,
    )
    db.commit()
    return _review_to_out(existing)


@router.post(
    "/progress/sync",
    response_model=SyncResponse,
    response_model_by_alias=True,
    summary="客户端上传本地学习进度 / 回顾，与服务端合并",
)
async def sync_progress(
    req: SyncRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
) -> SyncResponse:
    profile = ensure_student_profile(db, user)

    accepted_progress = 0
    for incoming in req.progress:
        existing = (
            db.query(LearningProgress)
            .filter(
                LearningProgress.student_id == profile.id,
                LearningProgress.section_id == incoming.section_id,
            )
            .first()
        )
        if existing is None:
            row = LearningProgress(
                student_id=profile.id,
                section_id=incoming.section_id,
                completed_rounds=incoming.completed_rounds,
                mastery_score=incoming.mastery_score,
                last_practiced_at=incoming.last_practiced_at,
                last_summary=incoming.last_summary,
            )
            db.add(row)
            accepted_progress += 1
            continue
        if req.mode == "overwrite":
            existing.completed_rounds = incoming.completed_rounds
            existing.mastery_score = incoming.mastery_score
            existing.last_practiced_at = incoming.last_practiced_at
            existing.last_summary = incoming.last_summary
            accepted_progress += 1
            continue
        # 合并：取较高 completedRounds 与较新 lastPracticedAt 为准。
        # 这避免「家长机器上手动重置 → 同步覆盖学生机器的真实进度」的情况。
        changed = False
        if incoming.completed_rounds > (existing.completed_rounds or 0):
            existing.completed_rounds = incoming.completed_rounds
            changed = True
        if incoming.mastery_score > (existing.mastery_score or 0):
            existing.mastery_score = incoming.mastery_score
            changed = True
        if incoming.last_practiced_at and (
            existing.last_practiced_at is None
            or incoming.last_practiced_at > existing.last_practiced_at
        ):
            existing.last_practiced_at = incoming.last_practiced_at
            changed = True
        if (
            incoming.last_summary
            and incoming.last_summary != (existing.last_summary or "")
            and (
                existing.last_practiced_at is None
                or (
                    incoming.last_practiced_at is not None
                    and incoming.last_practiced_at >= existing.last_practiced_at
                )
            )
        ):
            existing.last_summary = incoming.last_summary
            changed = True
        if changed:
            accepted_progress += 1

    accepted_reviews = 0
    for incoming in req.reviews:
        existing = (
            db.query(LectureReview)
            .filter(LectureReview.client_id == incoming.client_id)
            .first()
        )
        if existing is None:
            row = LectureReview(
                student_id=profile.id,
                client_id=incoming.client_id,
                section_id=incoming.section_id,
                question_id=incoming.question_id,
                question_prompt=incoming.question_prompt,
                difficulty=incoming.difficulty,
                tags_json=dump_json(incoming.tags),
                summary=incoming.summary,
                agent_highlights_json=dump_json(incoming.agent_highlights),
                caution_points_json=dump_json(incoming.caution_points),
                created_at=incoming.completed_at,
            )
            db.add(row)
            accepted_reviews += 1
            continue
        if existing.student_id != profile.id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Review belongs to another student.",
            )
        # 同 client_id 已存在：把字段补齐（容忍学生端在新增字段后重新上传）。
        existing.summary = incoming.summary or existing.summary
        existing.tags_json = dump_json(incoming.tags or load_json(existing.tags_json, []))
        existing.agent_highlights_json = dump_json(
            incoming.agent_highlights or load_json(existing.agent_highlights_json, [])
        )
        existing.caution_points_json = dump_json(
            incoming.caution_points or load_json(existing.caution_points_json, [])
        )

    from app.services.assignment_service import mark_assignments_completed

    for incoming in req.reviews:
        mark_assignments_completed(
            db,
            student_id=profile.id,
            section_id=incoming.section_id,
            question_id=incoming.question_id,
            review_client_id=incoming.client_id,
            summary=incoming.summary,
            agent_highlights=incoming.agent_highlights,
            caution_points=incoming.caution_points,
        )

    try:
        db.commit()
    except Exception as e:  # noqa: BLE001
        db.rollback()
        logger.exception("[learning] sync commit failed: %s", e)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to persist learning sync payload.",
        )

    progress_rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .order_by(LearningProgress.section_id.asc())
        .all()
    )
    review_rows = (
        db.query(LectureReview)
        .filter(LectureReview.student_id == profile.id)
        .order_by(LectureReview.created_at.desc())
        .limit(30)
        .all()
    )

    logger.info(
        "[learning] sync user=%s acc_progress=%d acc_reviews=%d "
        "total_progress=%d total_reviews=%d",
        user.username,
        accepted_progress,
        accepted_reviews,
        len(progress_rows),
        len(review_rows),
    )

    return SyncResponse(
        progress=[_progress_to_out(r) for r in progress_rows],
        reviews=[_review_to_out(r) for r in review_rows],
        accepted_progress=accepted_progress,
        accepted_reviews=accepted_reviews,
    )
