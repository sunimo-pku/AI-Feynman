"""第十一轮：游戏化、回放、商城、识题、知识检索与多孩子绑定 API。

这些接口都走真实表持久化；外部 OCR/Embedding/物流等核心依赖缺失时显式报错，
避免用演示数据伪装真实能力已经接通。
"""

from __future__ import annotations

import base64
import json
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, Depends, File, Header, HTTPException, Query, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    BountyAttempt,
    CrystalLedger,
    CrystalWallet,
    LeaderboardSnapshot,
    LearningProgress,
    LectureReplayRecord,
    ParentStudentLink,
    PowerEvent,
    RedeemOrder,
    SectionPower,
    StudentProfile,
    User,
    dump_json,
    ensure_student_profile,
    get_db,
    load_json,
)
from app.middleware.auth import require_user
from app.services import knowledge_index
from app.services.qwen_vision import recognize_question_image

router = APIRouter(tags=["Round11"])
_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_QUESTIONS_FILE = _PROJECT_ROOT / "data" / "questions" / "pep-junior-math-questions.json"

_SECTION_LABELS = {
    "pep-g8-down-s16-1": "16.1 二次根式的概念与取值范围",
    "pep-g8-down-s16-2": "16.2 二次根式的乘除",
    "pep-g8-down-s16-3": "16.3 二次根式的加减",
}
_TIERS = ((900, "王者"), (600, "黄金"), (300, "白银"), (0, "青铜"))

_SHOP_ITEMS = [
    {"skuId": "pen-gold", "name": "金色流光笔迹", "type": "penStyle", "crystalCost": 30},
    {"skuId": "frame-blue", "name": "湖青讲师头像框", "type": "avatarFrame", "crystalCost": 45},
]
_GEEK_SKUS = [
    {"skuId": "geek-compass", "name": "专业圆规套装", "type": "physical", "crystalCost": 120},
    {"skuId": "geek-timer", "name": "翻转番茄钟", "type": "physical", "crystalCost": 180},
    {"skuId": "geek-notebook", "name": "费曼错题本", "type": "physical", "crystalCost": 90},
]
_BOUNTIES = [
    {
        "challengeId": "bounty-s16-1-a",
        "sectionId": "pep-g8-down-s16-1",
        "prompt": r"小明写：$\sqrt{x-2}$ 有意义，所以 $x>2$。圈出错误并说明。",
        "wrongStep": r"$x>2$",
        "errorBox": {"x": 120, "y": 90, "width": 180, "height": 70},
        "rewardCrystals": 12,
        "rewardPower": 20,
    },
    {
        "challengeId": "bounty-s16-2-a",
        "sectionId": "pep-g8-down-s16-2",
        "prompt": r"大雄写：$\sqrt{-2}\cdot\sqrt{-8}=\sqrt{16}=4$。圈出错误并说明。",
        "wrongStep": r"$\sqrt{-2}\cdot\sqrt{-8}$",
        "errorBox": {"x": 88, "y": 100, "width": 260, "height": 76},
        "rewardCrystals": 15,
        "rewardPower": 24,
    },
    {
        "challengeId": "bounty-s16-3-a",
        "sectionId": "pep-g8-down-s16-3",
        "prompt": r"班长草稿：$\sqrt{12}-\sqrt{27}=2\sqrt3-3\sqrt3=\sqrt3$。",
        "wrongStep": r"$2\sqrt3-3\sqrt3=\sqrt3$",
        "errorBox": {"x": 180, "y": 120, "width": 280, "height": 72},
        "rewardCrystals": 15,
        "rewardPower": 24,
    },
]
class PowerAdjustRequest(BaseModel):
    section_id: str = Field(..., alias="sectionId")
    mastery_score: int = Field(0, alias="masteryScore", ge=0, le=100)
    completed_rounds: int = Field(0, alias="completedRounds", ge=0)
    bounty_wins: int = Field(0, alias="bountyWins", ge=0)
    reason: str = "manual"
    ref_id: str = Field("", alias="refId")

    model_config = {"populate_by_name": True}


class BountySubmitRequest(BaseModel):
    challenge_id: str = Field(..., alias="challengeId")
    circled_box: dict[str, float] = Field(default_factory=dict, alias="circledBox")
    transcript_text: str = Field("", alias="transcriptText")

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

    model_config = {"populate_by_name": True}


class BindStudentRequest(BaseModel):
    username: str
    nickname: str = ""


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
) -> CrystalWallet:
    wallet = _wallet(db, profile)
    if wallet.balance + amount < 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Crystal balance is not enough.")
    wallet.balance += amount
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


def _active_student_profile(
    db: Session,
    user: User,
    *,
    student_id: int | None,
    header_student_id: str | None,
) -> StudentProfile:
    own = ensure_student_profile(db, user)
    raw = student_id
    if raw is None and header_student_id:
        try:
            raw = int(header_student_id)
        except ValueError:
            raw = None
    if raw is None or raw == own.id:
        return own
    link = db.query(ParentStudentLink).filter(
        ParentStudentLink.parent_user_id == user.id,
        ParentStudentLink.student_profile_id == raw,
    ).first()
    if link is None:
        raise HTTPException(status_code=403, detail="Student is not bound to this parent.")
    profile = db.query(StudentProfile).filter(StudentProfile.id == raw).first()
    if profile is None:
        raise HTTPException(status_code=404, detail="Student profile not found.")
    return profile


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


@router.get("/gamification/me")
async def gamification_me(user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    powers = db.query(SectionPower).filter(SectionPower.student_id == profile.id).all()
    wallet = _wallet(db, profile)
    return {
        "studentName": profile.display_name or user.username,
        "equippedTitle": getattr(profile, "equipped_title", "") or "",
        "crystalBalance": wallet.balance,
        "sections": [_power_payload(p) for p in powers],
    }


@router.post("/gamification/power/adjust")
async def adjust_power(req: PowerAdjustRequest, user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    target = req.mastery_score * 10 + req.completed_rounds * 5 + req.bounty_wins * 15
    current = db.query(SectionPower).filter(
        SectionPower.student_id == profile.id,
        SectionPower.section_id == req.section_id,
    ).first()
    delta = max(0, target - int(current.power_score or 0)) if current else target
    row = _adjust_power(db, profile, req.section_id, delta, reason=req.reason, ref_id=req.ref_id)
    db.commit()
    db.refresh(row)
    return _power_payload(row)


@router.get("/leaderboard")
async def leaderboard(
    section_id: str = Query("pep-g8-down-s16-3", alias="sectionId"),
    scope: Literal["school", "district", "city", "province"] = "school",
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
):
    profile = ensure_student_profile(db, user)
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
    snapshots = db.query(LeaderboardSnapshot).filter(
        LeaderboardSnapshot.scope == scope,
        LeaderboardSnapshot.section_id == section_id,
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
        return {"scope": scope, "sectionId": section_id, "weekId": week_id, "entries": entries}

    rows = db.query(SectionPower).filter(
        SectionPower.section_id == section_id,
        SectionPower.student_id.in_(ids),
    ).order_by(SectionPower.power_score.desc()).limit(50).all()
    for idx, row in enumerate(rows, start=1):
        p = profiles.get(row.student_id)
        title = f"{getattr(p, scope_attr) if p else ''} · {_SECTION_LABELS.get(section_id, section_id)}第 {idx} 名"
        entries.append({
            "rank": idx,
            "studentId": row.student_id,
            "studentName": (p.display_name if p else "") or "同学",
            "powerScore": row.power_score,
            "rankTier": row.rank_tier,
            "titleLabel": title,
            "source": "realtime",
        })
    return {"scope": scope, "sectionId": section_id, "weekId": week_id, "entries": entries}


@router.get("/leaderboard/my-titles")
async def my_titles(user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    title = getattr(profile, "equipped_title", "") or "二次根式练习生"
    return {"equippedTitle": title, "titles": [title]}


@router.get("/bounty/today")
async def bounty_today():
    today = datetime.utcnow().date().toordinal()
    start = today % len(_BOUNTIES)
    return {"date": datetime.utcnow().date().isoformat(), "challenges": [_BOUNTIES[(start + i) % len(_BOUNTIES)] for i in range(3)]}


@router.post("/bounty/submit")
async def bounty_submit(req: BountySubmitRequest, user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    challenge = next((b for b in _BOUNTIES if b["challengeId"] == req.challenge_id), None)
    if challenge is None:
        raise HTTPException(status_code=404, detail="Bounty challenge not found.")
    circled = _iou(req.circled_box, challenge["errorBox"]) >= 0.25
    reward_crystals = int(challenge["rewardCrystals"] if circled and req.transcript_text.strip() else 0)
    reward_power = int(challenge["rewardPower"] if reward_crystals else 0)
    attempt = db.query(BountyAttempt).filter(
        BountyAttempt.student_id == profile.id,
        BountyAttempt.challenge_id == req.challenge_id,
    ).first()
    if attempt is None:
        attempt = BountyAttempt(student_id=profile.id, challenge_id=req.challenge_id, section_id=challenge["sectionId"])
        db.add(attempt)
    attempt.circled_correctly = 1 if circled else 0
    attempt.transcript_text = req.transcript_text
    attempt.crystal_reward = reward_crystals
    attempt.power_reward = reward_power
    if reward_crystals:
        _change_crystals(db, profile, reward_crystals, reason="bounty", ref_id=req.challenge_id)
        _adjust_power(db, profile, challenge["sectionId"], reward_power, reason="bounty", ref_id=req.challenge_id)
    db.commit()
    return {"completed": bool(reward_crystals), "circledCorrectly": circled, "crystalReward": reward_crystals, "powerReward": reward_power}


@router.get("/shop/catalog")
async def shop_catalog(user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    wallet = _wallet(db, profile)
    return {"balance": wallet.balance, "items": _SHOP_ITEMS, "geekSkus": _GEEK_SKUS}


@router.post("/shop/redeem")
async def shop_redeem(req: RedeemRequest, user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    sku = next((x for x in [*_SHOP_ITEMS, *_GEEK_SKUS] if x["skuId"] == req.sku_id), None)
    if sku is None:
        raise HTTPException(status_code=404, detail="SKU not found.")
    _change_crystals(db, profile, -int(sku["crystalCost"]), reason="redeem", ref_id=req.sku_id)
    order = None
    if sku.get("type") == "physical":
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
    return {"ok": True, "skuId": req.sku_id, "orderId": order.order_id if order else "", "status": order.status if order else "owned"}


@router.get("/shop/orders")
async def shop_orders(user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    rows = db.query(RedeemOrder).filter(RedeemOrder.student_id == profile.id).order_by(RedeemOrder.created_at.desc()).all()
    return {"orders": [{"orderId": r.order_id, "skuId": r.sku_id, "status": r.status, "crystalCost": r.crystal_cost, "createdAt": r.created_at} for r in rows]}


@router.get("/shop/ledger")
async def shop_ledger(user: User = Depends(require_user), db: Session = Depends(get_db)):
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
async def create_replay(req: ReplayRequest, user: User = Depends(require_user), db: Session = Depends(get_db)):
    profile = ensure_student_profile(db, user)
    row = db.query(LectureReplayRecord).filter(LectureReplayRecord.session_id == req.session_id).first()
    if row is None:
        row = LectureReplayRecord(student_id=profile.id, session_id=req.session_id, section_id=req.section_id, question_id=req.question_id)
        db.add(row)
    row.question_prompt = req.question_prompt
    row.audio_base64_chunks_json = dump_json(req.audio_base64_chunks)
    row.ink_timeline_json = dump_json(req.ink_timeline)
    row.turns_timeline_json = dump_json(req.turns_timeline)
    row.duration_ms = req.duration_ms
    db.commit()
    return {"sessionId": row.session_id, "ok": True}


@router.get("/parent/replays")
async def parent_replays(
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
    student_id: int | None = Query(None, alias="studentId"),
    x_student_id: str | None = Header(None, alias="X-Student-Id"),
):
    profile = _active_student_profile(db, user, student_id=student_id, header_student_id=x_student_id)
    rows = db.query(LectureReplayRecord).filter(LectureReplayRecord.student_id == profile.id).order_by(LectureReplayRecord.created_at.desc()).limit(20).all()
    return {"replays": [_replay_payload(r, include_timeline=False) for r in rows]}


@router.get("/replays/{session_id}")
async def get_replay(
    session_id: str,
    user: User = Depends(require_user),
    db: Session = Depends(get_db),
    student_id: int | None = Query(None, alias="studentId"),
    x_student_id: str | None = Header(None, alias="X-Student-Id"),
):
    profile = _active_student_profile(db, user, student_id=student_id, header_student_id=x_student_id)
    row = db.query(LectureReplayRecord).filter(
        LectureReplayRecord.student_id == profile.id,
        LectureReplayRecord.session_id == session_id,
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Replay not found.")
    return _replay_payload(row, include_timeline=True)


@router.post("/questions/upload-image")
async def upload_question_image(file: UploadFile = File(...), user: User = Depends(require_user)):
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


@router.get("/parent/children")
async def parent_children(user: User = Depends(require_user), db: Session = Depends(get_db)):
    links = db.query(ParentStudentLink).filter(ParentStudentLink.parent_user_id == user.id).all()
    if not links:
        profile = ensure_student_profile(db, user)
        return {"children": [{"studentId": profile.id, "nickname": profile.display_name or user.username, "active": True}]}
    children = []
    for link in links:
        profile = db.query(StudentProfile).filter(StudentProfile.id == link.student_profile_id).first()
        if profile:
            children.append({"studentId": profile.id, "nickname": link.nickname or profile.display_name, "active": False})
    return {"children": children}


@router.post("/parent/children/bind")
async def bind_child(req: BindStudentRequest, user: User = Depends(require_user), db: Session = Depends(get_db)):
    child_user = db.query(User).filter(User.username == req.username).first()
    if child_user is None:
        raise HTTPException(status_code=404, detail="Student username not found.")
    profile = ensure_student_profile(db, child_user)
    link = db.query(ParentStudentLink).filter(
        ParentStudentLink.parent_user_id == user.id,
        ParentStudentLink.student_profile_id == profile.id,
    ).first()
    if link is None:
        link = ParentStudentLink(parent_user_id=user.id, student_profile_id=profile.id)
        db.add(link)
    link.nickname = req.nickname or profile.display_name or child_user.username
    db.commit()
    return {"studentId": profile.id, "nickname": link.nickname}


def _replay_payload(row: LectureReplayRecord, *, include_timeline: bool) -> dict[str, Any]:
    payload = {
        "sessionId": row.session_id,
        "sectionId": row.section_id,
        "questionId": row.question_id,
        "questionPrompt": row.question_prompt,
        "durationMs": row.duration_ms,
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
