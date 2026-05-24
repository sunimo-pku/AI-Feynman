"""小节讲题档案（过程源画像）单元测试。"""

from __future__ import annotations

import uuid

from fastapi.testclient import TestClient

from app.db import (
    LearningProgress,
    LectureReview,
    SessionLocal,
    User,
    dump_json,
    ensure_student_profile,
)
from app.services.section_lecture_profile import (
    build_section_lecture_profile,
    resolve_section_profile_context,
)

DEFAULT_PARENT_PASSWORD = "parent-pass-12345"
SECTION_ID = "pep-g8-down-s16-1"


def _register_and_get_profile(client: TestClient) -> tuple[str, int]:
    username = f"stu{uuid.uuid4().hex[:10]}"
    resp = client.post(
        "/auth/register",
        json={
            "username": username,
            "password": "secret-pass-12345",
            "parentPassword": DEFAULT_PARENT_PASSWORD,
            "grade": "八年级",
        },
    )
    assert resp.status_code == 200, resp.text
    login = client.post(
        "/auth/login",
        json={"username": username, "password": "secret-pass-12345", "loginAs": "student"},
    )
    assert login.status_code == 200, login.text
    token = login.json()["token"]
    db = SessionLocal()
    try:
        user = db.query(User).filter(User.username == username).first()
        assert user is not None
        profile = ensure_student_profile(db, user)
        return token, profile.id
    finally:
        db.close()


def test_resolve_stars_only_without_student() -> None:
    ctx = resolve_section_profile_context(
        None,
        student=None,
        section_id=SECTION_ID,
        knowledge_point_id="pep-g8-down-s16-1-kp1",
        knowledge_point_stars=2,
    )
    assert "本节讲题档案" in ctx
    assert "2 星" in ctx
    assert "历史错因" not in ctx


def test_build_section_profile_includes_review_cautions() -> None:
    db = SessionLocal()
    try:
        username = f"stu{uuid.uuid4().hex[:10]}"
        user = User(username=username, password_hash="x", role="student")
        db.add(user)
        db.commit()
        db.refresh(user)
        profile = ensure_student_profile(db, user)
        db.add(
            LearningProgress(
                student_id=profile.id,
                section_id=SECTION_ID,
                mastery_score=30,
                completed_rounds=2,
            )
        )
        db.add(
            LectureReview(
                student_id=profile.id,
                client_id=f"rev-{uuid.uuid4().hex[:8]}",
                section_id=SECTION_ID,
                question_id="q1",
                question_prompt="test",
                difficulty=1,
                tags_json="[]",
                summary="summary",
                agent_highlights_json=dump_json(["小明曾问：被开方数要非负"]),
                caution_points_json=dump_json(["忘记写 x≥0"]),
                created_at=__import__("datetime").datetime.utcnow(),
            )
        )
        db.commit()

        out = build_section_lecture_profile(
            db,
            profile,
            SECTION_ID,
            knowledge_point_id="pep-g8-down-s16-1-kp1",
            knowledge_point_stars=1,
        )
        assert out.section_id == SECTION_ID
        assert out.mastery_score == 30
        assert "忘记写 x≥0" in out.prompt_context
        assert "1 星" in out.prompt_context
        assert out.difficulty_label == "基础"
    finally:
        db.rollback()
        db.close()


def test_get_section_profile_endpoint(client: TestClient) -> None:
    token, student_id = _register_and_get_profile(client)
    db = SessionLocal()
    try:
        db.add(
            LearningProgress(
                student_id=student_id,
                section_id=SECTION_ID,
                mastery_score=12,
                completed_rounds=1,
            )
        )
        db.commit()
    finally:
        db.close()

    resp = client.get(
        "/learning/section-profile",
        params={
            "sectionId": SECTION_ID,
            "knowledgePointId": "pep-g8-down-s16-1-kp2",
            "knowledgePointStars": 3,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["sectionId"] == SECTION_ID
    assert body["masteryScore"] == 12
    assert body["knowledgePointStars"] == 3
    assert "promptContext" in body
    assert body["difficultyLabel"] == "巩固"
