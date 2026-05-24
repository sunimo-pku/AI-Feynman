"""第十一轮：游戏化、回放、商城、识题、知识检索与多孩子绑定 API。

这些接口都走真实表持久化；外部 OCR/Embedding/物流等核心依赖缺失时显式报错，
避免用演示数据伪装真实能力已经接通。
"""

from __future__ import annotations

import base64
import json
import logging
import re
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, Depends, File, Header, HTTPException, Query, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.db import (
    BountyAttempt,
    CrystalLedger,
    CrystalWallet,
    LeaderboardSnapshot,
    LearningProgress,
    LectureReplayComment,
    LectureReplayRecord,
    LectureReplayLike,
    PowerEvent,
    RedeemOrder,
    SectionPower,
    StudentProfile,
    User,
    dump_json,
    ensure_student_profile,
    get_db,
    linked_child_profile,
    load_json,
)
from app.middleware.auth import (
    get_session_role,
    require_parent_user,
    require_student_user,
    require_user,
)
from app.services import knowledge_index
from app.services.qwen_vision import recognize_question_image
from app.services.replay_video import render_replay_mp4
from app.services.section_chapter import (
    chapter_in_student_grade,
    chapter_label,
    chapter_id_from_section_id,
    resolve_leaderboard_chapter_id,
    section_belongs_to_chapter,
)
from app.services.section_grade import section_in_student_grade

router = APIRouter(tags=["Round11"])
logger = logging.getLogger(__name__)
_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_QUESTIONS_FILE = _PROJECT_ROOT / "data" / "questions" / "pep-junior-math-questions.json"
_BOUNTY_FILE = _PROJECT_ROOT / "data" / "bounty" / "challenges.json"

_SECTION_LABELS: dict[str, str] = {}
_REPLAY_SESSION_ID_RE = re.compile(
    r"^(?:sess-)?(?:[0-9a-f]{32}|"
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$",
    re.IGNORECASE,
)
_LEGACY_REPLAY_SESSION_ID_RE = re.compile(r"^sess-\d{10,}-", re.IGNORECASE)


def _load_section_labels() -> dict[str, str]:
    labels: dict[str, str] = {}
    curriculum_file = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"
    try:
        payload = json.loads(curriculum_file.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return labels
    for book in payload.get("books", []):
        for chapter in book.get("chapters", []):
            for section in chapter.get("sections", []):
                sid = str(section.get("id") or "")
                label = str(section.get("label") or section.get("title") or "")
                if sid and label:
                    labels[sid] = label
    return labels


_SECTION_LABELS = _load_section_labels()


def _section_label(section_id: str) -> str:
    return _SECTION_LABELS.get(section_id, section_id)
_TIERS = ((900, "王者"), (600, "黄金"), (300, "白银"), (0, "青铜"))

_STATIONERY_SKUS_FILE = _PROJECT_ROOT / "data" / "shop" / "stationery_skus.json"


def _load_stationery_skus() -> list[dict]:
    try:
        raw = json.loads(_STATIONERY_SKUS_FILE.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            return [x for x in raw if isinstance(x, dict) and x.get("skuId")]
    except (OSError, json.JSONDecodeError) as e:
        logger.warning("[shop] failed to load stationery_skus.json: %s", e)
    return [
        {
            "skuId": "stat-notebook-a5",
            "name": "A5 讲题错题本",
            "type": "physical",
            "crystalCost": 88,
            "description": "占位文具",
        },
    ]


_SHOP_ITEMS = _load_stationery_skus()
# 第十二轮起商城仅实物文具；geekSkus 保留空数组以兼容旧客户端字段。
_GEEK_SKUS: list[dict] = []
class PowerAdjustRequest(BaseModel):
    section_id: str = Field(..., alias="sectionId")
    mastery_score: int = Field(0, alias="masteryScore", ge=0, le=100)
    completed_rounds: int = Field(0, alias="completedRounds", ge=0)
    bounty_wins: int = Field(0, alias="bountyWins", ge=0)
    reason: str = "manual"
    ref_id: str = Field("", alias="refId")

    model_config = {"populate_by_name": True}


class BountyStepAnswer(BaseModel):
    step_id: str = Field(..., alias="stepId")
    option_id: str = Field(..., alias="optionId")

    model_config = {"populate_by_name": True}


class BountySubmitRequest(BaseModel):
    challenge_id: str = Field(..., alias="challengeId")
    circled_box: dict[str, float] = Field(default_factory=dict, alias="circledBox")
    transcript_text: str = Field("", alias="transcriptText")
    step_answers: list[BountyStepAnswer] = Field(default_factory=list, alias="stepAnswers")

    model_config = {"populate_by_name": True}


class RedeemRequest(BaseModel):
    sku_id: str = Field(..., alias="skuId")
    address: dict[str, Any] = Field(default_factory=dict)

    model_config = {"populate_by_name": True}


class ReplayRequest(BaseModel):
    session_id: str = Field(default_factory=lambda: uuid.uuid4().hex, alias="sessionId")
    section_id: str = Field(..., alias="sectionId")
    question_id: str = Field(..., alias="questionId")
    question_prompt: str = Field("", alias="questionPrompt")
    audio_base64_chunks: list[str] = Field(default_factory=list, alias="audioBase64Chunks")
    ink_timeline: list[dict[str, Any]] = Field(default_factory=list, alias="inkTimeline")
    turns_timeline: list[dict[str, Any]] = Field(default_factory=list, alias="turnsTimeline")
    duration_ms: int = Field(0, alias="durationMs", ge=0)
    difficulty: int = Field(1, alias="difficulty", ge=1, le=3)

    model_config = {"populate_by_name": True}


class ReplayPublishRequest(BaseModel):
    description: str = Field("", max_length=120)
    is_public: bool = Field(True, alias="isPublic")

    model_config = {"populate_by_name": True}


class ReplayCommentRequest(BaseModel):
    body: str = Field(..., min_length=1, max_length=200)


def _tier(score: int) -> str:
    for threshold, name in _TIERS:
        if score >= threshold:
            return name
    return "青铜"


def _wallet(db: Session, profile: StudentProfile) -> CrystalWallet:
    wallet = db.query(CrystalWallet).filter(CrystalWallet.student_id == profile.id).first()
    if wallet is None:
        wallet = CrystalWallet(student_id=profile.id, balance=0)
        db.add(wallet)
        db.flush()
    return wallet


def _change_crystals(
    db: Session,
    profile: StudentProfile,
    amount: int,
    *,
    reason: str,
    ref_id: str,
    idempotent: bool = False,
) -> CrystalWallet:
    wallet = _wallet(db, profile)
    if idempotent and ref_id:
        existing = db.query(CrystalLedger).filter(
            CrystalLedger.student_id == profile.id,
            CrystalLedger.reason == reason,
            CrystalLedger.ref_id == ref_id,
        ).first()
        if existing is not None:
            return wallet
    if wallet.balance + amount < 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Crystal balance is not enough.")
    if amount < 0:
        result = db.execute(
            text(
                "UPDATE crystal_wallets "
                "SET balance = balance + :amount "
                "WHERE student_id = :student_id AND balance + :amount >= 0"
            ),
            {"amount": amount, "student_id": profile.id},
        )
        if result.rowcount != 1:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Crystal balance is not enough.",
            )
        db.refresh(wallet)
    else:
        wallet.balance += amount
        db.add(wallet)
    db.add(CrystalLedger(
        student_id=profile.id,
        amount=amount,
        reason=reason,
        ref_id=ref_id,
        balance_after=wallet.balance,
    ))
    return wallet


def _power_payload(row: SectionPower) -> dict[str, Any]:
    return {
        "sectionId": row.section_id,
        "powerScore": int(row.power_score or 0),
        "rankTier": row.rank_tier or _tier(int(row.power_score or 0)),
    }


def _chapter_power_payload(chapter_id: str, power_score: int) -> dict[str, Any]:
    return {
        "chapterId": chapter_id,
        "powerScore": power_score,
        "rankTier": _tier(power_score),
    }


def _aggregate_chapter_powers(rows: list[SectionPower]) -> list[dict[str, Any]]:
    """同一大章下各小节战力求和。"""
    totals: dict[str, int] = {}
    for row in rows:
        chapter_id = chapter_id_from_section_id(row.section_id)
        if not chapter_id:
            continue
        totals[chapter_id] = totals.get(chapter_id, 0) + int(row.power_score or 0)
    ordered = sorted(totals.items(), key=lambda item: (-item[1], item[0]))
    return [_chapter_power_payload(cid, score) for cid, score in ordered]


def _chapter_power_totals_for_students(
    db: Session,
    *,
    student_ids: list[int],
    chapter_id: str,
    grade: str,
) -> list[tuple[int, int]]:
    if not student_ids:
        return []
    rows = db.query(SectionPower).filter(SectionPower.student_id.in_(student_ids)).all()
    totals: dict[int, int] = {}
    for row in rows:
        if not section_belongs_to_chapter(row.section_id, chapter_id):
            continue
        if not section_in_student_grade(row.section_id, grade):
            continue
        totals[row.student_id] = totals.get(row.student_id, 0) + int(row.power_score or 0)
    return sorted(totals.items(), key=lambda item: (-item[1], item[0]))


def _replay_subject_profile(db: Session, user: User, session_role: str) -> StudentProfile:
    if session_role == "parent":
        profile = linked_child_profile(db, user)
        if profile is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="No child linked to this parent account.",
            )
        return profile
    return ensure_student_profile(db, user)


def _adjust_power(
    db: Session,
    profile: StudentProfile,
    section_id: str,
    delta: int,
    *,
    reason: str,
    ref_id: str,
) -> SectionPower:
    row = db.query(SectionPower).filter(
        SectionPower.student_id == profile.id,
        SectionPower.section_id == section_id,
    ).first()
    if row is None:
        row = SectionPower(student_id=profile.id, section_id=section_id, power_score=0)
        db.add(row)
    row.power_score = max(0, int(row.power_score or 0) + delta)
    row.rank_tier = _tier(row.power_score)
    db.add(PowerEvent(
        student_id=profile.id,
        section_id=section_id,
        delta=delta,
        reason=reason,
        ref_id=ref_id,
    ))
    return row


def _today_key() -> str:
    return datetime.utcnow().date().isoformat()


def _load_bounty_bank() -> list[dict[str, Any]]:
    try:
        raw = json.loads(_BOUNTY_FILE.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Bounty bank unavailable: {e}") from e
    items = raw.get("challenges") if isinstance(raw, dict) else []
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict) and item.get("challengeId")]


def _challenge_by_id(challenge_id: str) -> dict[str, Any] | None:
    return next((item for item in _load_bounty_bank() if item.get("challengeId") == challenge_id), None)


def _stable_offset(seed: str, size: int) -> int:
    if size <= 0:
        return 0
    return sum(ord(ch) for ch in seed) % size


def _attempt_key(date_key: str, challenge_id: str) -> str:
    return f"{date_key}:{challenge_id}"


def _base_challenge_id(stored_challenge_id: str) -> str:
    parts = stored_challenge_id.split(":", 1)
    if len(parts) == 2 and len(parts[0]) == 10:
        return parts[1]
    return stored_challenge_id


def _select_today_bounties(
    db: Session,
    profile: StudentProfile,
    *,
    date_key: str,
) -> list[dict[str, Any]]:
    grade = (profile.grade or "八年级").strip() or "八年级"
    bank = [
        item
        for item in _load_bounty_bank()
        if section_in_student_grade(str(item.get("sectionId") or ""), grade)
    ]
    if not bank:
        return []

    weak = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .order_by(LearningProgress.mastery_score.asc(), LearningProgress.updated_at.desc())
        .first()
    )
    weak_section_id = weak.section_id if weak else ""
    if weak_section_id and not section_in_student_grade(weak_section_id, grade):
        weak_section_id = ""
    selected: list[dict[str, Any]] = []
    used: set[str] = set()
    tracks = ("review", "weak", "advanced")
    for idx, track in enumerate(tracks):
        candidates = [item for item in bank if item.get("track") == track]
        if track == "weak" and weak_section_id:
            prioritized = [item for item in candidates if item.get("sectionId") == weak_section_id]
            if prioritized:
                candidates = prioritized
        if not candidates:
            candidates = bank
        start = _stable_offset(f"{date_key}:{profile.id}:{track}:{idx}", len(candidates))
        for step in range(len(candidates)):
            item = candidates[(start + step) % len(candidates)]
            challenge_id = str(item.get("challengeId") or "")
            if challenge_id and challenge_id not in used:
                selected.append(item)
                used.add(challenge_id)
                break
    if len(selected) < 3:
        for item in bank:
            challenge_id = str(item.get("challengeId") or "")
            if challenge_id and challenge_id not in used:
                selected.append(item)
                used.add(challenge_id)
            if len(selected) >= 3:
                break
    return selected[:3]


def _attempt_for(
    db: Session,
    profile: StudentProfile,
    *,
    challenge_id: str,
    date_key: str,
) -> BountyAttempt | None:
    attempt = db.query(BountyAttempt).filter(
        BountyAttempt.student_id == profile.id,
        BountyAttempt.challenge_id == _attempt_key(date_key, challenge_id),
        BountyAttempt.date_key == date_key,
    ).first()
    if attempt is not None:
        return attempt
    return db.query(BountyAttempt).filter(
        BountyAttempt.student_id == profile.id,
        BountyAttempt.challenge_id == challenge_id,
        BountyAttempt.date_key == date_key,
    ).first()


def _step_quizzes_for_challenge(challenge: dict[str, Any]) -> list[dict[str, Any]]:
    """把 wrongSolution 拆成逐步选择题（服务端生成，题库无需手写每题选项）。"""
    custom = challenge.get("stepQuizzes")
    if isinstance(custom, list) and custom:
        return [item for item in custom if isinstance(item, dict) and item.get("stepId")]

    lines = [str(line).strip() for line in (challenge.get("wrongSolution") or []) if str(line).strip()]
    error_step_id = str(challenge.get("errorStepId") or "step-2")
    quizzes: list[dict[str, Any]] = []
    for i, line in enumerate(lines):
        step_id = f"step-{i + 1}"
        is_error = step_id == error_step_id
        quizzes.append({
            "stepId": step_id,
            "index": i + 1,
            "statement": line,
            "prompt": f"第 {i + 1} 步有没有问题？",
            "options": [
                {"optionId": "ok", "label": "这一步没问题"},
                {"optionId": "wrong", "label": "错误出在这一步"},
                {"optionId": "unsure", "label": "还不确定"},
            ],
            "correctOptionId": "wrong" if is_error else "ok",
        })
    return quizzes


def _public_step_quizzes_for_challenge(challenge: dict[str, Any]) -> list[dict[str, Any]]:
    public: list[dict[str, Any]] = []
    for quiz in _step_quizzes_for_challenge(challenge):
        item = dict(quiz)
        item.pop("correctOptionId", None)
        public.append(item)
    return public


def _score_step_answers(
    challenge: dict[str, Any],
    step_answers: list[dict[str, str]],
) -> tuple[bool, float, list[str]]:
    quizzes = _step_quizzes_for_challenge(challenge)
    if not quizzes:
        return False, 0.0, []
    expected = {str(q["stepId"]): str(q["correctOptionId"]) for q in quizzes}
    picked: dict[str, str] = {}
    for item in step_answers:
        sid = str(item.get("stepId") or item.get("step_id") or "").strip()
        oid = str(item.get("optionId") or item.get("option_id") or "").strip()
        if sid and oid:
            picked[sid] = oid
    missed: list[str] = []
    correct = 0
    for sid, want in expected.items():
        if picked.get(sid) == want:
            correct += 1
        else:
            missed.append(sid)
    score = correct / len(expected) if expected else 0.0
    # 必须每步都答对，且覆盖全部步骤
    passed = len(missed) == 0 and len(picked) >= len(expected)
    return passed, score, missed


def _feedback_payload(
    *,
    circled: bool,
    iou_score: float,
    explanation_score: int,
    completed: bool,
    keyword_hits: list[str],
    mcq_mode: bool = True,
) -> dict[str, Any]:
    if completed:
        summary = "逐步判断和板书讲解都达标了，今日挑战奖励已发放。"
        next_hint = "可以在白板上再写一遍正确解法加深印象。"
    elif mcq_mode and not circled:
        summary = "还有解题步骤没判断对，请找出真正出错的那一步。"
        next_hint = "回看同学的解法，逐步点选；找出后再在白板上讲清为什么错。"
    elif not circled:
        summary = "选择题还没有全部判断正确。"
        next_hint = "逐步检查同学的每一步，标出出错的那一步。"
    else:
        summary = "步骤判断对了，板书讲解还要更清楚地说出错因和正确做法。"
        next_hint = "在白板上写出正确步骤，并用语音说明：错在哪、规则是什么、结果应该怎样。"
    return {
        "summary": summary,
        "nextHint": next_hint,
        "iouScore": round(iou_score, 3),
        "mcqScore": round(iou_score, 3),
        "explanationScore": explanation_score,
        "keywordHits": keyword_hits[:6],
    }


def _score_explanation(challenge: dict[str, Any], text_value: str) -> tuple[int, list[str]]:
    normalized = text_value.lower().replace(" ", "")
    keywords = [str(k) for k in challenge.get("rubricKeywords", []) if str(k).strip()]
    hits = [kw for kw in keywords if kw.lower().replace(" ", "") in normalized]
    if not hits:
        return 0, []
    length = len(text_value.strip())
    length_score = 20 if length >= 24 else (10 if length >= 12 else 0)
    hit_score = min(70, len(hits) * 35)
    structure_score = 10 if any(mark in text_value for mark in ("所以", "因为", "应该", "正确")) else 0
    return min(100, length_score + hit_score + structure_score), hits


def _validate_replay_session_id(session_id: str) -> str:
    value = session_id.strip()
    if not value:
        return uuid.uuid4().hex
    if _LEGACY_REPLAY_SESSION_ID_RE.match(value) or not _REPLAY_SESSION_ID_RE.fullmatch(value):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Replay sessionId must be a high-entropy UUID value.",
        )
    return value


def _bounty_status(attempt: BountyAttempt | None) -> str:
    if attempt is None or int(attempt.attempt_count or 0) == 0:
        return "notStarted"
    if attempt.reward_granted_at is not None or int(attempt.crystal_reward or 0) > 0:
        return "completed"
    return "inProgress"


def _day_bounty_completed(
    db: Session,
    profile: StudentProfile,
    *,
    date_key: str,
) -> bool:
    challenges = _select_today_bounties(db, profile, date_key=date_key)
    if not challenges:
        return False
    for item in challenges:
        challenge_id = str(item.get("challengeId") or "")
        attempt = _attempt_for(
            db,
            profile,
            challenge_id=challenge_id,
            date_key=date_key,
        )
        if attempt is None or attempt.reward_granted_at is None:
            return False
    return True


def _bounty_streak_days(db: Session, profile: StudentProfile) -> int:
    """连续打卡：按 UTC 自然日计，当日 3 题全完成算打卡成功；今日未完成则从昨日往前数。"""
    today = datetime.utcnow().date()
    cursor = today
    if not _day_bounty_completed(db, profile, date_key=today.isoformat()):
        cursor = today - timedelta(days=1)
    streak = 0
    while _day_bounty_completed(db, profile, date_key=cursor.isoformat()):
        streak += 1
        cursor -= timedelta(days=1)
    return streak


def _bounty_public(challenge: dict[str, Any], attempt: BountyAttempt | None) -> dict[str, Any]:
    feedback = load_json(attempt.feedback_json, {}) if attempt else {}
    return {
        "challengeId": challenge.get("challengeId", ""),
        "track": challenge.get("track", "review"),
        "sectionId": challenge.get("sectionId", ""),
        "questionId": challenge.get("questionId", ""),
        "sectionLabel": challenge.get("sectionLabel", ""),
        "prompt": challenge.get("prompt", ""),
        "wrongStep": challenge.get("wrongStep", ""),
        "wrongSolution": challenge.get("wrongSolution", []),
        "tags": challenge.get("tags", []),
        "difficulty": int(challenge.get("difficulty") or 1),
        "rewardCrystals": int(challenge.get("rewardCrystals") or 0),
        "rewardPower": int(challenge.get("rewardPower") or 0),
        "canvasWidth": 640,
        "canvasHeight": 360,
        "status": _bounty_status(attempt),
        "attemptCount": int(attempt.attempt_count or 0) if attempt else 0,
        "circledCorrectly": bool(attempt.circled_correctly) if attempt else False,
        "explanationScore": int(attempt.explanation_score or 0) if attempt else 0,
        "feedback": feedback,
        "rewardGranted": bool(attempt and (attempt.reward_granted_at is not None or int(attempt.crystal_reward or 0) > 0)),
        "stepQuizzes": _public_step_quizzes_for_challenge(challenge),
    }


@router.get("/gamification/me")
async def gamification_me(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    grade = (profile.grade or "八年级").strip() or "八年级"
    powers = db.query(SectionPower).filter(SectionPower.student_id == profile.id).all()
    in_grade = [p for p in powers if section_in_student_grade(p.section_id, grade)]
    wallet = _wallet(db, profile)
    return {
        "studentName": profile.display_name or user.username,
        "equippedTitle": getattr(profile, "equipped_title", "") or "",
        "crystalBalance": wallet.balance,
        "grade": grade,
        "chapters": _aggregate_chapter_powers(in_grade),
    }


@router.post("/gamification/power/adjust")
async def adjust_power(req: PowerAdjustRequest, user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Client-side power adjustment is disabled.",
    )


@router.get("/leaderboard")
async def leaderboard(
    chapter_id: str = Query("pep-g8-down-ch16", alias="chapterId"),
    section_id: str | None = Query(None, alias="sectionId"),
    scope: Literal["school", "district", "city", "province"] = "school",
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
    grade = (profile.grade or "八年级").strip() or "八年级"
    resolved_chapter_id = resolve_leaderboard_chapter_id(section_id or chapter_id)
    if not resolved_chapter_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid chapterId or sectionId.",
        )
    if not chapter_in_student_grade(resolved_chapter_id, grade):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Leaderboard chapter must belong to {grade}.",
        )
    scope_attr = {
        "school": "school_name",
        "district": "district",
        "city": "city",
        "province": "province",
    }[scope]
    same_area = db.query(StudentProfile).filter(
        getattr(StudentProfile, scope_attr) == getattr(profile, scope_attr)
    ).all()
    ids = [p.id for p in same_area]
    week_id = _week_id(datetime.utcnow() - timedelta(days=7))
    chapter_label_text = chapter_label(resolved_chapter_id)
    snapshots = db.query(LeaderboardSnapshot).filter(
        LeaderboardSnapshot.scope == scope,
        LeaderboardSnapshot.section_id == resolved_chapter_id,
        LeaderboardSnapshot.week_id == week_id,
        LeaderboardSnapshot.student_id.in_(ids),
    ).order_by(LeaderboardSnapshot.rank.asc()).limit(50).all()
    profiles = {p.id: p for p in same_area}
    entries = []
    if snapshots:
        for row in snapshots:
            p = profiles.get(row.student_id)
            entries.append({
                "rank": row.rank,
                "studentId": row.student_id,
                "studentName": (p.display_name if p else "") or "同学",
                "powerScore": row.power_score,
                "rankTier": _tier(int(row.power_score or 0)),
                "titleLabel": row.title_label,
                "source": "snapshot",
            })
        return {
            "scope": scope,
            "chapterId": resolved_chapter_id,
            "sectionId": resolved_chapter_id,
            "weekId": week_id,
            "entries": entries,
        }

    ranked = _chapter_power_totals_for_students(
        db,
        student_ids=ids,
        chapter_id=resolved_chapter_id,
        grade=grade,
    )
    for idx, (student_id, total_score) in enumerate(ranked[:50], start=1):
        p = profiles.get(student_id)
        title = f"{getattr(p, scope_attr) if p else ''} · {chapter_label_text}第 {idx} 名"
        entries.append({
            "rank": idx,
            "studentId": student_id,
            "studentName": (p.display_name if p else "") or "同学",
            "powerScore": total_score,
            "rankTier": _tier(total_score),
            "titleLabel": title,
            "source": "realtime",
        })
    return {
        "scope": scope,
        "chapterId": resolved_chapter_id,
        "sectionId": resolved_chapter_id,
        "weekId": week_id,
        "entries": entries,
    }


@router.get("/leaderboard/my-titles")
async def my_titles(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    title = getattr(profile, "equipped_title", "") or "数学练习生"
    return {"equippedTitle": title, "titles": [title]}


@router.get("/bounty/today")
async def bounty_today(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    date_key = _today_key()
    challenges = _select_today_bounties(db, profile, date_key=date_key)
    attempts = {
        _base_challenge_id(row.challenge_id): row
        for row in db.query(BountyAttempt).filter(
            BountyAttempt.student_id == profile.id,
            BountyAttempt.date_key == date_key,
        ).all()
    }
    public = [_bounty_public(item, attempts.get(str(item.get("challengeId") or ""))) for item in challenges]
    streak_days = _bounty_streak_days(db, profile)
    return {
        "date": date_key,
        "dateKey": date_key,
        "completedCount": sum(1 for item in public if item["status"] == "completed"),
        "totalCount": len(public),
        "totalCrystals": sum(int(item["rewardCrystals"] or 0) for item in public),
        "streakDays": streak_days,
        "challenges": public,
    }


@router.post("/bounty/submit")
async def bounty_submit(req: BountySubmitRequest, user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    date_key = _today_key()
    todays = _select_today_bounties(db, profile, date_key=date_key)
    challenge = next((b for b in todays if b.get("challengeId") == req.challenge_id), None)
    if challenge is None:
        challenge = _challenge_by_id(req.challenge_id)
    if challenge is None:
        raise HTTPException(status_code=404, detail="Bounty challenge not found.")
    if challenge not in todays:
        raise HTTPException(status_code=400, detail="Bounty challenge is not in today's set.")

    quizzes = _step_quizzes_for_challenge(challenge)
    if not req.step_answers:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="请完成所有步骤的选择题后再提交。",
        )
    step_payload = [
        {"stepId": a.step_id, "optionId": a.option_id}
        for a in req.step_answers
    ]
    circled, iou_score, _missed = _score_step_answers(challenge, step_payload)
    selected_payload: dict[str, Any] = {"mode": "mcq", "stepAnswers": step_payload}
    explanation_score, keyword_hits = _score_explanation(challenge, req.transcript_text.strip())
    completed = circled and explanation_score >= 60
    reward_crystals = int(challenge["rewardCrystals"] if completed else 0)
    reward_power = int(challenge["rewardPower"] if completed else 0)
    attempt = _attempt_for(
        db,
        profile,
        challenge_id=req.challenge_id,
        date_key=date_key,
    )
    if attempt is None:
        attempt = BountyAttempt(
            student_id=profile.id,
            date_key=date_key,
            challenge_id=_attempt_key(date_key, req.challenge_id),
            section_id=challenge["sectionId"],
        )
        db.add(attempt)
    attempt.date_key = date_key
    attempt.section_id = str(challenge.get("sectionId") or attempt.section_id)
    attempt.circled_correctly = 1 if circled else 0
    attempt.selected_box_json = dump_json(selected_payload)
    attempt.iou_score = iou_score
    attempt.explanation_score = explanation_score
    attempt.feedback_json = dump_json(_feedback_payload(
        circled=circled,
        iou_score=iou_score,
        explanation_score=explanation_score,
        completed=completed,
        keyword_hits=keyword_hits,
        mcq_mode=True,
    ))
    attempt.attempt_count = int(attempt.attempt_count or 0) + 1
    attempt.transcript_text = req.transcript_text
    already_rewarded = attempt.reward_granted_at is not None or int(attempt.crystal_reward or 0) > 0
    granted_now = bool(completed and not already_rewarded)
    reward_ref_id = _attempt_key(date_key, req.challenge_id)
    if granted_now:
        attempt.crystal_reward = reward_crystals
        attempt.power_reward = reward_power
        attempt.reward_granted_at = datetime.utcnow()
        attempt.completed_at = datetime.utcnow()
        _change_crystals(
            db,
            profile,
            reward_crystals,
            reason="bounty",
            ref_id=reward_ref_id,
            idempotent=True,
        )
        _adjust_power(db, profile, challenge["sectionId"], reward_power, reason="bounty", ref_id=reward_ref_id)
    elif completed and attempt.completed_at is None:
        attempt.completed_at = datetime.utcnow()
    db.commit()
    db.refresh(attempt)
    return {
        "completed": completed,
        "status": _bounty_status(attempt),
        "circledCorrectly": circled,
        "mcqCorrect": circled,
        "iouScore": round(iou_score, 3),
        "mcqScore": round(iou_score, 3),
        "explanationScore": explanation_score,
        "crystalReward": reward_crystals if granted_now else 0,
        "powerReward": reward_power if granted_now else 0,
        "rewardGranted": granted_now,
        "feedback": load_json(attempt.feedback_json, {}),
        "attemptCount": int(attempt.attempt_count or 0),
    }


@router.get("/bounty/history")
async def bounty_history(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    rows = db.query(BountyAttempt).filter(
        BountyAttempt.student_id == profile.id,
    ).order_by(BountyAttempt.completed_at.desc()).limit(30).all()
    return {
        "history": [
            {
                "dateKey": row.date_key,
                "challengeId": _base_challenge_id(row.challenge_id),
                "sectionId": row.section_id,
                "status": _bounty_status(row),
                "circledCorrectly": bool(row.circled_correctly),
                "explanationScore": int(row.explanation_score or 0),
                "crystalReward": int(row.crystal_reward or 0),
                "powerReward": int(row.power_reward or 0),
                "completedAt": row.completed_at,
                "feedback": load_json(row.feedback_json, {}),
            }
            for row in rows
        ]
    }


@router.get("/shop/catalog")
async def shop_catalog(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    wallet = _wallet(db, profile)
    return {"balance": wallet.balance, "items": _SHOP_ITEMS, "geekSkus": _GEEK_SKUS}


@router.post("/shop/redeem")
async def shop_redeem(req: RedeemRequest, user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    sku = next((x for x in [*_SHOP_ITEMS, *_GEEK_SKUS] if x["skuId"] == req.sku_id), None)
    if sku is None:
        raise HTTPException(status_code=404, detail="SKU not found.")
    if sku.get("type") != "physical":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only physical stationery can be redeemed.",
        )
    addr = req.address or {}
    ship_name = str(addr.get("name") or "").strip()
    ship_phone = str(addr.get("phone") or "").strip()
    ship_address = str(addr.get("address") or "").strip()
    if not ship_name or not ship_phone or not ship_address:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Shipping name, phone and address are required.",
        )
    _change_crystals(db, profile, -int(sku["crystalCost"]), reason="redeem", ref_id=req.sku_id)
    order = RedeemOrder(
        order_id=uuid.uuid4().hex,
        sku_id=req.sku_id,
        student_id=profile.id,
        status="pending",
        crystal_cost=int(sku["crystalCost"]),
        address_json=dump_json(req.address),
    )
    db.add(order)
    db.commit()
    return {"ok": True, "skuId": req.sku_id, "orderId": order.order_id, "status": order.status}


@router.get("/shop/orders")
async def shop_orders(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    rows = db.query(RedeemOrder).filter(RedeemOrder.student_id == profile.id).order_by(RedeemOrder.created_at.desc()).all()
    return {"orders": [{"orderId": r.order_id, "skuId": r.sku_id, "status": r.status, "crystalCost": r.crystal_cost, "createdAt": r.created_at} for r in rows]}


@router.get("/shop/ledger")
async def shop_ledger(user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    wallet = _wallet(db, profile)
    rows = db.query(CrystalLedger).filter(CrystalLedger.student_id == profile.id).order_by(CrystalLedger.created_at.desc()).limit(30).all()
    return {
        "balance": wallet.balance,
        "ledger": [
            {
                "amount": r.amount,
                "reason": r.reason,
                "refId": r.ref_id,
                "balanceAfter": r.balance_after,
                "createdAt": r.created_at,
            }
            for r in rows
        ],
    }


@router.post("/replays")
async def create_replay(req: ReplayRequest, user: User = Depends(require_student_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    session_id = _validate_replay_session_id(req.session_id)
    row = db.query(LectureReplayRecord).filter(LectureReplayRecord.session_id == session_id).first()
    if row is None:
        row = LectureReplayRecord(student_id=profile.id, session_id=session_id, section_id=req.section_id, question_id=req.question_id)
        db.add(row)
    elif row.student_id != profile.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Replay session belongs to another student.",
        )
    row.question_prompt = req.question_prompt
    row.audio_base64_chunks_json = dump_json(req.audio_base64_chunks)
    row.ink_timeline_json = dump_json(req.ink_timeline)
    row.turns_timeline_json = dump_json(req.turns_timeline)
    row.duration_ms = req.duration_ms
    row.difficulty = req.difficulty
    db.commit()
    return {"sessionId": row.session_id, "ok": True}


@router.get("/parent/replays")
async def parent_replays(
    user: User = Depends(require_parent_user),
    session_role: str = Depends(get_session_role),
    db: Session = Depends(get_db),
):
    profile = _replay_subject_profile(db, user, session_role)
    rows = db.query(LectureReplayRecord).filter(LectureReplayRecord.student_id == profile.id).order_by(LectureReplayRecord.created_at.desc()).limit(20).all()
    return {"replays": [_replay_payload(r, include_timeline=False, db=db) for r in rows]}


@router.get("/replays/public")
async def public_replays(
    section_id: str | None = Query(None, alias="sectionId"),
    question_id: str | None = Query(None, alias="questionId"),
    limit: int = Query(20, ge=1, le=50),
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
):
    viewer = ensure_student_profile(db, user) if user.role == "student" else linked_child_profile(db, user)
    query = db.query(LectureReplayRecord).filter(LectureReplayRecord.is_public == 1)
    if section_id:
        query = query.filter(LectureReplayRecord.section_id == section_id)
    if question_id:
        query = query.filter(LectureReplayRecord.question_id == question_id)
    if question_id:
        query = query.order_by(
            LectureReplayRecord.like_count.desc(),
            LectureReplayRecord.published_at.desc(),
            LectureReplayRecord.created_at.desc(),
        )
    else:
        query = query.order_by(LectureReplayRecord.published_at.desc(), LectureReplayRecord.created_at.desc())
    rows = query.limit(limit).all()
    liked_ids: set[int] = set()
    if viewer is not None and rows:
        replay_ids = [int(r.id) for r in rows]
        liked_ids = {
            int(x[0])
            for x in db.query(LectureReplayLike.replay_id)
            .filter(
                LectureReplayLike.student_id == viewer.id,
                LectureReplayLike.replay_id.in_(replay_ids),
            )
            .all()
        }
    return {
        "replays": [
            _replay_payload(
                r,
                include_timeline=False,
                db=db,
                viewer_student_id=viewer.id if viewer is not None else None,
                liked_replay_ids=liked_ids,
            )
            for r in rows
        ]
    }


@router.get("/replays/{session_id}")
async def get_replay(
    session_id: str,
    user: User = Depends(require_user),
    session_role: str = Depends(get_session_role),
    db: Session = Depends(get_db),
):
    profile = _replay_subject_profile(db, user, session_role)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.session_id == session_id,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    if row.student_id != profile.id and not row.is_public:
        raise HTTPException(status_code=404, detail="Replay not found.")
    liked = (
        db.query(LectureReplayLike)
        .filter(LectureReplayLike.student_id == profile.id, LectureReplayLike.replay_id == row.id)
        .first()
        is not None
    )
    return _replay_payload(row, include_timeline=True, db=db, viewer_student_id=profile.id, liked_override=liked)


@router.post("/replays/{session_id}/publish")
async def publish_replay(
    session_id: str,
    req: ReplayPublishRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.student_id == profile.id,
        LectureReplayRecord.session_id == session_id,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    row.is_public = 1 if req.is_public else 0
    row.publish_description = req.description.strip()[:120]
    if req.is_public and row.published_at is None:
        row.published_at = datetime.utcnow()
    if req.is_public:
        try:
            row.video_url = render_replay_mp4(
                session_id=row.session_id,
                question_prompt=row.question_prompt,
                description=row.publish_description or "",
                duration_ms=int(row.duration_ms or 0),
                audio_base64_chunks=load_json(row.audio_base64_chunks_json, []),
                ink_timeline=load_json(row.ink_timeline_json, []),
                turns_timeline=load_json(row.turns_timeline_json, []),
            )
        except Exception as e:  # noqa: BLE001
            logger.exception("[replay] mp4 render failed session=%s: %s", session_id, e)
            raise HTTPException(status_code=502, detail="Replay video render failed.") from e
    db.commit()
    db.refresh(row)
    return _replay_payload(row, include_timeline=False, db=db, viewer_student_id=profile.id, liked_override=False)


@router.post("/replays/{session_id}/like")
async def like_replay(
    session_id: str,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.session_id == session_id,
        LectureReplayRecord.is_public == 1,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    existing = db.query(LectureReplayLike).filter(
        LectureReplayLike.student_id == profile.id,
        LectureReplayLike.replay_id == row.id,
    ).first()
    if existing is None:
        db.add(LectureReplayLike(student_id=profile.id, replay_id=row.id))
        row.like_count = int(row.like_count or 0) + 1
        db.commit()
        db.refresh(row)
    return {"sessionId": row.session_id, "liked": True, "likeCount": int(row.like_count or 0)}


@router.delete("/replays/{session_id}/like")
async def unlike_replay(
    session_id: str,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.session_id == session_id,
        LectureReplayRecord.is_public == 1,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    existing = db.query(LectureReplayLike).filter(
        LectureReplayLike.student_id == profile.id,
        LectureReplayLike.replay_id == row.id,
    ).first()
    if existing is not None:
        db.delete(existing)
        row.like_count = max(0, int(row.like_count or 0) - 1)
        db.commit()
        db.refresh(row)
    return {"sessionId": row.session_id, "liked": False, "likeCount": int(row.like_count or 0)}


@router.get("/replays/{session_id}/comments")
async def replay_comments(
    session_id: str,
    user: User = Depends(require_user),
    session_role: str = Depends(get_session_role),
    db: Session = Depends(get_db),
):
    profile = _replay_subject_profile(db, user, session_role)
    row = db.query(LectureReplayRecord).filter(LectureReplayRecord.session_id == session_id).first()
    if row is None or (row.student_id != profile.id and not row.is_public):
        raise HTTPException(status_code=404, detail="Replay not found.")
    comments = (
        db.query(LectureReplayComment, StudentProfile)
        .join(StudentProfile, StudentProfile.id == LectureReplayComment.student_id)
        .filter(LectureReplayComment.replay_id == row.id)
        .order_by(LectureReplayComment.created_at.desc())
        .limit(50)
        .all()
    )
    return {
        "comments": [
            {
                "commentId": c.id,
                "studentName": p.display_name or "同学",
                "body": c.body,
                "createdAt": c.created_at,
                "isMine": c.student_id == profile.id,
            }
            for c, p in comments
        ]
    }


@router.post("/replays/{session_id}/comments")
async def create_replay_comment(
    session_id: str,
    req: ReplayCommentRequest,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.session_id == session_id,
        LectureReplayRecord.is_public == 1,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    comment = LectureReplayComment(
        replay_id=row.id,
        student_id=profile.id,
        body=req.body.strip()[:200],
    )
    db.add(comment)
    db.commit()
    db.refresh(comment)
    return {
        "commentId": comment.id,
        "studentName": profile.display_name or "同学",
        "body": comment.body,
        "createdAt": comment.created_at,
        "isMine": True,
    }


@router.post("/questions/upload-image")
async def upload_question_image(file: UploadFile = File(...), user: User = Depends(require_student_user)):
    data = await file.read()
    preview = base64.b64encode(data[:24]).decode("ascii")
    image_base64 = base64.b64encode(data).decode("ascii") if data else ""
    vision = recognize_question_image(
        image_base64=image_base64,
        mime_type=file.content_type or "image/jpeg",
    )
    if not vision.get("error"):
        return {**vision, "debugPreview": preview}
    raise HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail=f"Question vision failed: {vision.get('error')}",
    )


@router.get("/questions")
async def questions(section_id: str = Query(..., alias="sectionId")):
    try:
        raw = json.loads(_QUESTIONS_FILE.read_text(encoding="utf-8"))
        items = raw.get("questions") if isinstance(raw, dict) else []
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Question bank unavailable: {e}") from e
    if not isinstance(items, list):
        return {"questions": []}
    return {
        "questions": [
            item for item in items
            if isinstance(item, dict) and item.get("sectionId") == section_id
        ]
    }


@router.post("/knowledge/search")
async def knowledge_search(payload: dict[str, Any]):
    query = str(payload.get("query") or "")
    section_id = str(payload.get("sectionId") or payload.get("section_id") or "").strip() or None
    top_k = int(payload.get("topK") or payload.get("top_k") or 3)
    hits = knowledge_index.search(query, section_id=section_id, top_k=top_k)
    return {"hits": hits, "source": "local_json_keyword"}


def _replay_payload(
    row: LectureReplayRecord,
    *,
    include_timeline: bool,
    db: Session,
    viewer_student_id: int | None = None,
    liked_replay_ids: set[int] | None = None,
    liked_override: bool | None = None,
) -> dict[str, Any]:
    owner = row.student_id == viewer_student_id if viewer_student_id is not None else False
    liked = bool(liked_override) if liked_override is not None else bool(liked_replay_ids and int(row.id) in liked_replay_ids)
    author = db.query(StudentProfile).filter(StudentProfile.id == row.student_id).first()
    power = db.query(SectionPower).filter(
        SectionPower.student_id == row.student_id,
        SectionPower.section_id == row.section_id,
    ).first()
    author_name = (author.display_name if author is not None else "") or "同学"
    rank_tier = (power.rank_tier if power is not None else "") or "青铜"
    comment_count = db.query(LectureReplayComment).filter(LectureReplayComment.replay_id == row.id).count()
    payload = {
        "sessionId": row.session_id,
        "sectionId": row.section_id,
        "sectionLabel": _section_label(row.section_id),
        "questionId": row.question_id,
        "questionPrompt": row.question_prompt,
        "durationMs": row.duration_ms,
        "difficulty": int(row.difficulty or 1),
        "isPublic": bool(row.is_public),
        "description": row.publish_description or "",
        "likeCount": int(row.like_count or 0),
        "likedByMe": liked,
        "isMine": owner,
        "videoUrl": row.video_url or "",
        "commentCount": comment_count,
        "authorName": author_name,
        "authorInitial": author_name.strip()[:1] or "同",
        "authorRankTier": rank_tier,
        "publishedAt": row.published_at,
        "createdAt": row.created_at,
    }
    if include_timeline:
        payload.update({
            "audioBase64Chunks": load_json(row.audio_base64_chunks_json, []),
            "inkTimeline": load_json(row.ink_timeline_json, []),
            "turnsTimeline": load_json(row.turns_timeline_json, []),
        })
    return payload


def _iou(a: dict[str, float], b: dict[str, float]) -> float:
    ax1, ay1 = float(a.get("x", 0)), float(a.get("y", 0))
    ax2, ay2 = ax1 + float(a.get("width", 0)), ay1 + float(a.get("height", 0))
    bx1, by1 = float(b.get("x", 0)), float(b.get("y", 0))
    bx2, by2 = bx1 + float(b.get("width", 0)), by1 + float(b.get("height", 0))
    inter_w = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    inter_h = max(0.0, min(ay2, by2) - max(ay1, by1))
    inter = inter_w * inter_h
    union = max(1.0, (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter)
    return inter / union


def _week_id(dt: datetime) -> str:
    iso = dt.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"
