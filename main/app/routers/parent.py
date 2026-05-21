"""家长端 API（第十轮）。

V1 不做复杂的多孩子家庭权限模型：登录用户**即**学生主体；家长端就是
另一个客户端入口，请求同一个账号的数据。这层简单的语义把家长端「最小
可用」做完，避免被 OAuth / RBAC 拖延。

提供：

- `GET /parent/dashboard`：学生总体掌握度、弱项 sections、最近讲题、本周建议。
- `GET /parent/reviews`：最近回顾摘要，按 section 过滤。
- `GET /parent/poster`：「总结海报」用的结构化数据。

字段一律 camelCase 出，与 Flutter `ParentDashboardPayload` 对齐。
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureReview,
    LectureSessionRecord,
    User,
    ensure_student_profile,
    get_db,
    load_json,
)
from app.middleware.auth import require_user

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/parent", tags=["Parent"])


# ---------------------------------------------------------------------------
# Section 标签元数据：和 lecture_agent / mock_lecture_repository 对齐。
# ---------------------------------------------------------------------------


_SECTION_LABEL: dict[str, str] = {
    "pep-g8-down-s16-1": "16.1 二次根式的概念与取值范围",
    "pep-g8-down-s16-2": "16.2 二次根式的乘除",
    "pep-g8-down-s16-3": "16.3 二次根式的加减",
}

_SECTION_WEAK_REASON: dict[str, str] = {
    "pep-g8-down-s16-1": "被开方数非负条件容易写漏",
    "pep-g8-down-s16-2": "乘除法则前提条件不稳定",
    "pep-g8-down-s16-3": "同类二次根式合并时系数符号易错",
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
        return "今天可以从「16.1 二次根式的概念与取值范围」开始，先把基础打稳。"
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


@router.get(
    "/dashboard",
    response_model=DashboardOut,
    response_model_by_alias=True,
    summary="家长 dashboard：弱项 / 最近讲题 / 教师建议",
)
async def parent_dashboard(
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
) -> DashboardOut:
    profile = ensure_student_profile(db, user)
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
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
    section_id: str | None = Query(None, alias="sectionId", max_length=64),
    limit: int = Query(20, ge=1, le=50),
) -> list[ReviewCardOut]:
    profile = ensure_student_profile(db, user)
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
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
) -> PosterOut:
    profile = ensure_student_profile(db, user)
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
