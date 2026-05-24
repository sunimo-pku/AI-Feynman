"""小节讲题档案（过程源画像）。

与 ``learning_profile.build_learning_profile``（全册规划画像）分离：
- 全册画像：简略，用于今日 Tab / 家长板 / 作业推荐；
- 本节档案：详细，用于实时追问 / hint / 李老师收束。

数据源以 **本节 / 同题讲题过程** 为主（Review 错因、同伴追问摘录、
未完成会话），**不**做全册 weak 排序。知识点星级由客户端 ``session_start``
传入，作为辅助一行上下文。
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureReview,
    LectureSessionRecord,
    StudentProfile,
    load_json,
)
from app.services.learning_profile import _label_for, _reason_for, _trim

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"

_DIFFICULTY_FOR_STARS = {1: "基础", 2: "巩固", 3: "挑战"}
_MAX_CAUTIONS = 5
_MAX_HIGHLIGHTS = 4


class SectionLectureProfileOut(BaseModel):
    section_id: str = Field("", serialization_alias="sectionId")
    section_label: str = Field("", serialization_alias="sectionLabel")
    chapter_title: str = Field("", serialization_alias="chapterTitle")
    mastery_score: int = Field(0, serialization_alias="masteryScore")
    completed_rounds: int = Field(0, serialization_alias="completedRounds")
    knowledge_point_id: str = Field("", serialization_alias="knowledgePointId")
    knowledge_point_label: str = Field("", serialization_alias="knowledgePointLabel")
    knowledge_point_stars: int = Field(-1, serialization_alias="knowledgePointStars")
    difficulty_label: str = Field("", serialization_alias="difficultyLabel")
    recent_cautions: list[str] = Field(default_factory=list, serialization_alias="recentCautions")
    recent_highlights: list[str] = Field(
        default_factory=list, serialization_alias="recentHighlights"
    )
    incomplete_session_count: int = Field(
        0, serialization_alias="incompleteSessionCount"
    )
    prompt_context: str = Field("", serialization_alias="promptContext")

    model_config = {"populate_by_name": True}


def _load_kp_labels() -> dict[str, str]:
    labels: dict[str, str] = {}
    try:
        payload = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover
        logger.warning("section profile: curriculum load failed: %s", exc)
        return labels
    for book in payload.get("books", []):
        for chapter in book.get("chapters", []):
            for section in chapter.get("sections", []):
                for kp in section.get("knowledgePoints") or []:
                    if not isinstance(kp, dict):
                        continue
                    kid = str(kp.get("id") or "").strip()
                    label = str(kp.get("label") or "").strip()
                    if kid and label:
                        labels[kid] = label
    return labels


_KP_LABELS: dict[str, str] | None = None


def _kp_label(knowledge_point_id: str) -> str:
    global _KP_LABELS  # noqa: PLW0603
    if _KP_LABELS is None:
        _KP_LABELS = _load_kp_labels()
    kid = (knowledge_point_id or "").strip()
    return _KP_LABELS.get(kid, kid)


def _chapter_for_section(section_id: str) -> str:
    from app.services.learning_profile import _SECTION_CHAPTER

    return _SECTION_CHAPTER.get(section_id, "")


def _difficulty_label_for_stars(stars: int) -> str:
    if stars < 0:
        return ""
    target = 1 if stars <= 1 else (2 if stars <= 3 else 3)
    return _DIFFICULTY_FOR_STARS.get(target, "基础")


def _stars_only_prompt_context(
    *,
    section_id: str,
    knowledge_point_id: str,
    knowledge_point_stars: int,
) -> str:
    lines = [
        "【本节讲题档案 · 仅供背景，不得替代本轮白板/语音证据】",
        f"- 当前小节：{_label_for(section_id)}",
    ]
    if knowledge_point_id:
        diff = _difficulty_label_for_stars(knowledge_point_stars)
        kp_label = _kp_label(knowledge_point_id)
        star_text = f"{knowledge_point_stars} 星" if knowledge_point_stars >= 0 else "未同步"
        diff_bit = f" · 选题档位：{diff}" if diff else ""
        lines.append(
            f"- 当前知识点：{kp_label} · {star_text}{diff_bit}"
        )
    lines.append(
        "- 规则：只能帮助选追问角度；`understood` 仍只看本轮是否讲清。"
    )
    return "\n".join(lines)


def format_section_profile_prompt(profile: SectionLectureProfileOut) -> str:
    if profile.prompt_context.strip():
        return profile.prompt_context.strip()
    return _stars_only_prompt_context(
        section_id=profile.section_id,
        knowledge_point_id=profile.knowledge_point_id,
        knowledge_point_stars=profile.knowledge_point_stars,
    )


def build_section_lecture_profile(
    db: Session,
    student: StudentProfile,
    section_id: str,
    *,
    knowledge_point_id: str = "",
    knowledge_point_stars: int = -1,
) -> SectionLectureProfileOut:
    """聚合当前小节详细讲题档案，供追问 Prompt 注入。"""

    sid = (section_id or "").strip()
    kp_id = (knowledge_point_id or "").strip()
    stars = int(knowledge_point_stars)

    progress = (
        db.query(LearningProgress)
        .filter(
            LearningProgress.student_id == student.id,
            LearningProgress.section_id == sid,
        )
        .first()
    )
    mastery = int(progress.mastery_score or 0) if progress else 0
    rounds = int(progress.completed_rounds or 0) if progress else 0

    reviews = (
        db.query(LectureReview)
        .filter(
            LectureReview.student_id == student.id,
            LectureReview.section_id == sid,
        )
        .order_by(LectureReview.created_at.desc())
        .limit(12)
        .all()
    )

    incomplete_count = (
        db.query(LectureSessionRecord)
        .filter(
            LectureSessionRecord.student_id == student.id,
            LectureSessionRecord.section_id == sid,
            LectureSessionRecord.status != "completed",
        )
        .count()
    )

    cautions: list[str] = []
    seen_caution: set[str] = set()
    highlights: list[str] = []
    seen_highlight: set[str] = set()

    for review in reviews:
        for item in load_json(review.caution_points_json, []) or []:
            text = _trim(str(item or ""), 64)
            if text and text not in seen_caution:
                seen_caution.add(text)
                cautions.append(text)
            if len(cautions) >= _MAX_CAUTIONS:
                break
        for item in load_json(review.agent_highlights_json, []) or []:
            text = _trim(str(item or ""), 72)
            if text and text not in seen_highlight:
                seen_highlight.add(text)
                highlights.append(text)
            if len(highlights) >= _MAX_HIGHLIGHTS:
                break
        if len(cautions) >= _MAX_CAUTIONS and len(highlights) >= _MAX_HIGHLIGHTS:
            break

    diff_label = _difficulty_label_for_stars(stars) if kp_id else ""
    section_label = _label_for(sid)
    chapter_title = _chapter_for_section(sid)

    lines = [
        "【本节讲题档案 · 仅供背景，不得替代本轮白板/语音证据】",
        f"- 当前小节：{section_label} · 掌握 {mastery}/100 · 已完成 {rounds} 轮讲题",
    ]
    if chapter_title:
        lines.append(f"- 所属章节：{chapter_title} · 常见卡点：{_reason_for(sid)}")
    if kp_id:
        star_text = f"{stars} 星" if stars >= 0 else "未同步"
        diff_bit = f" · 选题档位：{diff_label}" if diff_label else ""
        lines.append(
            f"- 当前知识点：{_kp_label(kp_id)} · {star_text}{diff_bit}"
        )
    if cautions:
        lines.append(f"- 历史错因（最近）：{'；'.join(cautions[:3])}")
    if highlights:
        lines.append(f"- 同伴曾追问：{'；'.join(highlights[:2])}")
    if incomplete_count > 0:
        lines.append(
            f"- 未完成讲题：{incomplete_count} 次（适合在关键条件上继续逼问）"
        )
    if rounds == 0 and not cautions:
        lines.append("- 本节尚无落库讲题记录，请只依据本轮题面与白板/语音追问。")
    lines.append(
        "- 规则：以上只能帮助选追问角度；`understood` 仍只看本轮是否讲清，"
        "不要因为历史弱就放水或预判一定答错。"
    )

    return SectionLectureProfileOut(
        section_id=sid,
        section_label=section_label,
        chapter_title=chapter_title,
        mastery_score=mastery,
        completed_rounds=rounds,
        knowledge_point_id=kp_id,
        knowledge_point_label=_kp_label(kp_id) if kp_id else "",
        knowledge_point_stars=stars,
        difficulty_label=diff_label,
        recent_cautions=cautions,
        recent_highlights=highlights,
        incomplete_session_count=incomplete_count,
        prompt_context="\n".join(lines),
    )


def resolve_section_profile_context(
    db: Session | None,
    *,
    student: StudentProfile | None,
    section_id: str,
    knowledge_point_id: str = "",
    knowledge_point_stars: int = -1,
) -> str:
    """登录用户走 DB 聚合；匿名或未登录仅拼星级行。"""
    sid = (section_id or "").strip()
    if not sid:
        return ""
    if db is not None and student is not None:
        profile = build_section_lecture_profile(
            db,
            student,
            sid,
            knowledge_point_id=knowledge_point_id,
            knowledge_point_stars=knowledge_point_stars,
        )
        return format_section_profile_prompt(profile)
    return _stars_only_prompt_context(
        section_id=sid,
        knowledge_point_id=knowledge_point_id,
        knowledge_point_stars=knowledge_point_stars,
    )
