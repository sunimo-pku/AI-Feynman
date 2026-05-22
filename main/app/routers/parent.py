"""家长端 API（第十轮 + 账号模型修订）。

一名家长账号对应一名孩子（注册时绑定）。家长登录需账号密码 + 家长密码。
学生账号无法访问家长端接口。

提供：

- `GET /parent/dashboard`：绑定孩子的掌握度、弱项、最近讲题、教师建议。
- `GET /parent/reviews`：最近回顾摘要，按 section 过滤。
- `GET /parent/poster`：「总结海报」用的结构化数据。
- `PATCH /parent/profile`：编辑绑定孩子的展示名与年级。
- `GET /parent/children`：返回唯一绑定的孩子（兼容旧客户端）。
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureReview,
    LectureSessionRecord,
    ParentStudentLink,
    StudentProfile,
    User,
    get_db,
    linked_child_profile,
    load_json,
)
from app.middleware.auth import require_parent_user

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/parent", tags=["Parent"])


# ---------------------------------------------------------------------------
# Section 标签元数据：从课程目录读取，避免在 API 层硬编码某个章节标题。
# ---------------------------------------------------------------------------


_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"


def _load_section_labels() -> dict[str, str]:
    try:
        payload = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover - startup diagnostic only
        logger.warning("Failed to load curriculum labels: %s", exc)
        return {}

    labels: dict[str, str] = {}
    for book in payload.get("books", []):
        for chapter in book.get("chapters", []):
            for section in chapter.get("sections", []):
                section_id = str(section.get("id") or "")
                label = str(section.get("label") or section.get("title") or "")
                if section_id and label:
                    labels[section_id] = label
    return labels


_SECTION_LABEL: dict[str, str] = _load_section_labels()

_SECTION_WEAK_REASON: dict[str, str] = {
    "pep-g8-down-s16-1": "取值范围条件容易写漏",
    "pep-g8-down-s16-2": "公式法则前提条件不稳定",
    "pep-g8-down-s16-3": "合并运算时系数符号易错",
}


# ---------------------------------------------------------------------------
# IO 模型
# ---------------------------------------------------------------------------


class WeakSectionOut(BaseModel):
    section_id: str = Field(..., serialization_alias="sectionId")
    label: str
    mastery_score: int = Field(0, serialization_alias="masteryScore")
    completed_rounds: int = Field(0, serialization_alias="completedRounds")
    reason: str = ""
    last_practiced_at: datetime | None = Field(
        None, serialization_alias="lastPracticedAt"
    )

    model_config = {"populate_by_name": True}


class ReviewCardOut(BaseModel):
    client_id: str = Field(..., serialization_alias="id")
    section_id: str = Field(..., serialization_alias="sectionId")
    section_label: str = Field("", serialization_alias="sectionLabel")
    question_id: str = Field(..., serialization_alias="questionId")
    question_prompt: str = Field("", serialization_alias="questionPrompt")
    summary: str = ""
    completed_at: datetime = Field(..., serialization_alias="completedAt")
    difficulty: int = 1
    tags: list[str] = Field(default_factory=list)
    caution_points: list[str] = Field(
        default_factory=list, serialization_alias="cautionPoints"
    )

    model_config = {"populate_by_name": True}


class DashboardOut(BaseModel):
    student_name: str = Field(..., serialization_alias="studentName")
    grade: str
    overall_mastery: int = Field(0, serialization_alias="overallMastery")
    practiced_sections: int = Field(0, serialization_alias="practicedSections")
    completed_rounds: int = Field(0, serialization_alias="completedRounds")
    weak_sections: list[WeakSectionOut] = Field(
        default_factory=list, serialization_alias="weakSections"
    )
    strong_sections: list[WeakSectionOut] = Field(
        default_factory=list, serialization_alias="strongSections"
    )
    recent_reviews: list[ReviewCardOut] = Field(
        default_factory=list, serialization_alias="recentReviews"
    )
    suggested_next_action: str = Field(
        "", serialization_alias="suggestedNextAction"
    )
    server_time: datetime = Field(
        default_factory=datetime.utcnow, serialization_alias="serverTime"
    )

    model_config = {"populate_by_name": True}


class ParentProfilePatch(BaseModel):
    display_name: str | None = Field(None, alias="displayName")
    grade: str | None = None

    model_config = {"populate_by_name": True}


class PosterOut(BaseModel):
    student_name: str = Field(..., serialization_alias="studentName")
    grade: str
    week_completed_rounds: int = Field(0, serialization_alias="weekCompletedRounds")
    highest_section: str = Field("", serialization_alias="highestSection")
    highest_score: int = Field(0, serialization_alias="highestScore")
    weakest_section: str = Field("", serialization_alias="weakestSection")
    weakest_score: int = Field(0, serialization_alias="weakestScore")
    teacher_tip: str = Field("", serialization_alias="teacherTip")
    last_question_prompt: str = Field("", serialization_alias="lastQuestionPrompt")
    last_summary: str = Field("", serialization_alias="lastSummary")
    generated_at: datetime = Field(
        default_factory=datetime.utcnow, serialization_alias="generatedAt"
    )

    model_config = {"populate_by_name": True}


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------


def _label_for(section_id: str) -> str:
    return _SECTION_LABEL.get(section_id, section_id)


def _reason_for(section_id: str) -> str:
    return _SECTION_WEAK_REASON.get(section_id, "近期练习覆盖不足")


def _review_to_card(row: LectureReview) -> ReviewCardOut:
    return ReviewCardOut(
        client_id=row.client_id,
        section_id=row.section_id,
        section_label=_label_for(row.section_id),
        question_id=row.question_id,
        question_prompt=row.question_prompt or "",
        summary=row.summary or "",
        completed_at=row.created_at,
        difficulty=int(row.difficulty or 1),
        tags=list(load_json(row.tags_json, []) or []),
        caution_points=list(load_json(row.caution_points_json, []) or []),
    )


def _require_linked_child(db: Session, user: User) -> StudentProfile:
    profile = linked_child_profile(db, user)
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No child linked to this parent account.",
        )
    return profile


def _progress_to_weak(row: LearningProgress) -> WeakSectionOut:
    return WeakSectionOut(
        section_id=row.section_id,
        label=_label_for(row.section_id),
        mastery_score=int(row.mastery_score or 0),
        completed_rounds=int(row.completed_rounds or 0),
        reason=_reason_for(row.section_id),
        last_practiced_at=row.last_practiced_at,
    )


def _build_suggested_action(
    weak: list[WeakSectionOut],
    recent: list[ReviewCardOut],
    practiced_count: int,
) -> str:
    """按弱项 + 最近讲题拼一句教师风格的下一步建议。

    规则（V1，本地拼装、不调 LLM）：
    1. 若 practiced_count == 0：鼓励今天先开一节练手；
    2. 若有 weak section：建议今天先复讲它，附上「reason」；
    3. 若没有 weak 但有 recent：肯定 + 建议挑战下一难度题；
    4. 兜底：通用鼓励。
    """

    if practiced_count == 0:
        return "今天可以先选一个小节讲一题，把基础讲清楚。"
    if weak:
        target = weak[0]
        return (
            f"建议今天先复讲「{target.label}」"
            f"（当前掌握度 {target.mastery_score}/100，{target.reason}）。"
        )
    if recent:
        return (
            "近期基础题已经讲得不错，可以挑战同小节的巩固/挑战难度，"
            "看看是否能把规则用引号原话讲给同学听。"
        )
    return "保持每天 10-15 分钟讲题节奏，效果最稳。"


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------


@router.get("/children")
async def parent_children(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = linked_child_profile(db, user)
    if profile is None:
        return {"children": []}
    link = (
        db.query(ParentStudentLink)
        .filter(ParentStudentLink.parent_user_id == user.id)
        .first()
    )
    nickname = link.nickname if link else profile.display_name
    return {
        "children": [
            {
                "studentId": profile.id,
                "nickname": nickname or profile.display_name,
                "active": True,
            }
        ]
    }


@router.patch("/profile")
async def patch_child_profile(
    req: ParentProfilePatch,
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    profile = _require_linked_child(db, user)
    if req.display_name is not None:
        profile.display_name = req.display_name.strip() or profile.display_name
    if req.grade is not None:
        profile.grade = req.grade.strip() or profile.grade
    db.commit()
    db.refresh(profile)
    return {
        "displayName": profile.display_name,
        "grade": profile.grade,
    }


@router.get(
    "/dashboard",
    response_model=DashboardOut,
    response_model_by_alias=True,
    summary="家长 dashboard：弱项 / 最近讲题 / 教师建议",
)
async def parent_dashboard(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
) -> DashboardOut:
    profile = _require_linked_child(db, user)
    progress_rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .all()
    )
    review_rows = (
        db.query(LectureReview)
        .filter(LectureReview.student_id == profile.id)
        .order_by(LectureReview.created_at.desc())
        .limit(8)
        .all()
    )

    practiced = [p for p in progress_rows if (p.completed_rounds or 0) > 0]
    overall = (
        round(sum(int(p.mastery_score or 0) for p in practiced) / len(practiced))
        if practiced
        else 0
    )
    total_rounds = sum(int(p.completed_rounds or 0) for p in progress_rows)

    # 弱项：练习过但 mastery_score < 60 的 section，按分数升序取前 3。
    weak = sorted(
        [p for p in practiced if int(p.mastery_score or 0) < 60],
        key=lambda r: int(r.mastery_score or 0),
    )[:3]
    strong = sorted(
        [p for p in practiced if int(p.mastery_score or 0) >= 60],
        key=lambda r: -int(r.mastery_score or 0),
    )[:3]

    weak_out = [_progress_to_weak(r) for r in weak]
    strong_out = [_progress_to_weak(r) for r in strong]
    review_out = [_review_to_card(r) for r in review_rows]

    suggestion = _build_suggested_action(
        weak_out,
        review_out,
        len(practiced),
    )

    return DashboardOut(
        student_name=profile.display_name or user.username,
        grade=profile.grade or "八年级",
        overall_mastery=overall,
        practiced_sections=len(practiced),
        completed_rounds=total_rounds,
        weak_sections=weak_out,
        strong_sections=strong_out,
        recent_reviews=review_out,
        suggested_next_action=suggestion,
    )


@router.get(
    "/reviews",
    response_model=list[ReviewCardOut],
    response_model_by_alias=True,
)
async def parent_reviews(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
    section_id: str | None = Query(None, alias="sectionId", max_length=64),
    limit: int = Query(20, ge=1, le=50),
) -> list[ReviewCardOut]:
    profile = _require_linked_child(db, user)
    q = db.query(LectureReview).filter(LectureReview.student_id == profile.id)
    if section_id:
        q = q.filter(LectureReview.section_id == section_id)
    rows = q.order_by(LectureReview.created_at.desc()).limit(limit).all()
    return [_review_to_card(r) for r in rows]


@router.get(
    "/poster",
    response_model=PosterOut,
    response_model_by_alias=True,
    summary="家长端总结海报：本周完成轮数 / 最强 / 最弱 / 教师建议",
)
async def parent_poster(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
) -> PosterOut:
    profile = _require_linked_child(db, user)
    progress_rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .all()
    )
    week_ago = datetime.utcnow() - timedelta(days=7)
    week_reviews = (
        db.query(LectureReview)
        .filter(
            LectureReview.student_id == profile.id,
            LectureReview.created_at >= week_ago,
        )
        .order_by(LectureReview.created_at.desc())
        .all()
    )

    practiced = [p for p in progress_rows if (p.completed_rounds or 0) > 0]
    if practiced:
        highest = max(practiced, key=lambda r: int(r.mastery_score or 0))
        weakest = min(practiced, key=lambda r: int(r.mastery_score or 0))
        highest_label = _label_for(highest.section_id)
        highest_score = int(highest.mastery_score or 0)
        weakest_label = _label_for(weakest.section_id)
        weakest_score = int(weakest.mastery_score or 0)
    else:
        highest_label = ""
        highest_score = 0
        weakest_label = ""
        weakest_score = 0

    if not practiced:
        tip = "今天先开始 10 分钟讲题，从 16.1 起步。"
    elif weakest_score < 60:
        tip = (
            f"建议本周再复讲一次「{weakest_label}」，"
            f"重点把{_reason_for(weakest.section_id if practiced else '')}讲清楚。"
        )
    else:
        tip = "整体状态不错，可以挑战同小节的巩固/挑战题，把规则讲给同伴听。"

    last_prompt = week_reviews[0].question_prompt if week_reviews else ""
    last_summary = week_reviews[0].summary if week_reviews else ""

    return PosterOut(
        student_name=profile.display_name or user.username,
        grade=profile.grade or "八年级",
        week_completed_rounds=len(week_reviews),
        highest_section=highest_label,
        highest_score=highest_score,
        weakest_section=weakest_label,
        weakest_score=weakest_score,
        teacher_tip=tip,
        last_question_prompt=last_prompt,
        last_summary=last_summary,
    )
