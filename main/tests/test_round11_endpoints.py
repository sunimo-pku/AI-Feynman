from __future__ import annotations

import uuid
import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).parent))
from test_round10_endpoints import (
    _login,
    _register_and_login,
    _register_parent,
    _register_student,
)


def _grant_power(username: str, section_id: str, delta: int) -> None:
    from app.db import SessionLocal, User, ensure_student_profile  # noqa: WPS433
    from app.routers.round11 import _adjust_power  # noqa: WPS433

    db = SessionLocal()
    try:
        user = db.query(User).filter(User.username == username).first()
        assert user is not None
        profile = ensure_student_profile(db, user)
        _adjust_power(
            db,
            profile,
            section_id,
            delta,
            reason="test",
            ref_id=f"test-{uuid.uuid4().hex}",
        )
        db.commit()
    finally:
        db.close()


def _grant_crystals(username: str, amount: int) -> None:
    from app.db import SessionLocal, User, ensure_student_profile  # noqa: WPS433
    from app.routers.round11 import _change_crystals  # noqa: WPS433

    db = SessionLocal()
    try:
        user = db.query(User).filter(User.username == username).first()
        assert user is not None
        profile = ensure_student_profile(db, user)
        _change_crystals(
            db,
            profile,
            amount,
            reason="test",
            ref_id=f"test-{uuid.uuid4().hex}",
        )
        db.commit()
    finally:
        db.close()


def _server_answers_for(challenge_id: str) -> list[dict[str, str]]:
    from app.routers.round11 import _challenge_by_id, _step_quizzes_for_challenge  # noqa: WPS433

    challenge = _challenge_by_id(challenge_id)
    assert challenge is not None
    return [
        {"stepId": q["stepId"], "optionId": q["correctOptionId"]}
        for q in _step_quizzes_for_challenge(challenge)
    ]


def _rubric_explanation_for(challenge_id: str) -> str:
    from app.routers.round11 import _challenge_by_id  # noqa: WPS433

    challenge = _challenge_by_id(challenge_id)
    assert challenge is not None
    keywords = [str(k) for k in challenge.get("rubricKeywords", []) if str(k).strip()]
    core = "、".join(keywords[:2] or ["错因", "正确做法"])
    return f"因为这里要看 {core}，所以原来的步骤不对，应该按这个规则重新写出正确结果。"


def test_profile_reviews_gamification_shop_replay_knowledge(client: TestClient) -> None:
    username = f"r11{uuid.uuid4().hex[:8]}"
    token = _register_and_login(client, username)
    headers = {"Authorization": f"Bearer {token}"}

    resp = client.patch(
        "/learning/profile",
        headers=headers,
        json={"displayName": "小太阳", "grade": "八年级"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["displayName"] == "小太阳"

    review = {
        "id": f"rev-{uuid.uuid4().hex}",
        "sectionId": "pep-g8-down-s16-3",
        "questionId": "q-s16-3-001",
        "questionPrompt": "化简",
        "difficulty": 1,
        "tags": ["化简"],
        "completedAt": "2026-05-22T03:00:00",
        "summary": "讲清楚了",
        "agentHighlights": [],
        "cautionPoints": [],
    }
    assert client.post("/learning/reviews", headers=headers, json=review).status_code == 200

    resp = client.post(
        "/gamification/power/adjust",
        headers=headers,
        json={
            "sectionId": "pep-g8-down-s16-3",
            "masteryScore": 30,
            "completedRounds": 2,
            "bountyWins": 1,
        },
    )
    assert resp.status_code == 403, resp.text

    assert client.get("/leaderboard?sectionId=pep-g8-down-s16-3&scope=school", headers=headers).status_code == 200
    assert client.get("/shop/catalog", headers=headers).status_code == 200
    assert client.post(
        "/replays",
        headers=headers,
        json={
            "sessionId": f"sess-{uuid.uuid4().hex}",
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q",
            "inkTimeline": [{"tMs": 0, "points": []}],
            "turnsTimeline": [{"tMs": 10, "text": "好"}],
            "durationMs": 100,
        },
    ).status_code == 200

    child_name, child_password = _register_student(client, f"replay-child{uuid.uuid4().hex[:6]}")
    _, _, parent_token = _register_parent(client, child_name)
    assert client.get("/parent/replays", headers={"Authorization": f"Bearer {parent_token}"}).status_code == 200
    assert client.post("/knowledge/search", json={"query": "同类二次根式"}).status_code == 200


def test_bounty_and_parent_registration(client: TestClient) -> None:
    child_name, child_password = _register_student(client, f"child{uuid.uuid4().hex[:6]}")
    child_token = _login(client, child_name, child_password)
    student_headers = {"Authorization": f"Bearer {child_token}"}

    _, _, parent_token = _register_parent(client, child_name)
    parent_headers = {"Authorization": f"Bearer {parent_token}"}
    children = client.get("/parent/children", headers=parent_headers).json()["children"]
    assert len(children) == 1
    assert children[0]["studentId"] > 0

    assert client.get("/bounty/today").status_code == 401
    today = client.get("/bounty/today", headers=student_headers)
    assert today.status_code == 200
    today_body = today.json()
    assert isinstance(today_body.get("streakDays"), int)
    assert today_body["streakDays"] >= 0
    challenge = today_body["challenges"][0]
    quizzes = challenge.get("stepQuizzes") or []
    assert len(quizzes) >= 2
    assert all("correctOptionId" not in q for q in quizzes)
    answers = _server_answers_for(challenge["challengeId"])
    cheat = client.post(
        "/bounty/submit",
        headers=student_headers,
        json={
            "challengeId": challenge["challengeId"],
            "stepAnswers": answers,
            "transcriptText": "因为所以应该正确，接着然后最后因此所以应该正确。",
        },
    )
    assert cheat.status_code == 200, cheat.text
    assert cheat.json()["completed"] is False
    assert cheat.json()["explanationScore"] < 60
    submit = client.post(
        "/bounty/submit",
        headers=student_headers,
        json={
            "challengeId": challenge["challengeId"],
            "stepAnswers": answers,
            "transcriptText": _rubric_explanation_for(challenge["challengeId"]),
        },
    )
    assert submit.status_code == 200
    body = submit.json()
    assert body["mcqCorrect"] is True
    assert body["explanationScore"] >= 60
    assert body["crystalReward"] > 0
    duplicate = client.post(
        "/bounty/submit",
        headers=student_headers,
        json={
            "challengeId": challenge["challengeId"],
            "stepAnswers": answers,
            "transcriptText": _rubric_explanation_for(challenge["challengeId"]),
        },
    )
    assert duplicate.status_code == 200, duplicate.text
    assert duplicate.json()["completed"] is True
    assert duplicate.json()["crystalReward"] == 0
    assert duplicate.json()["powerReward"] == 0
    ledger = client.get("/shop/ledger", headers=student_headers).json()["ledger"]
    assert sum(1 for row in ledger if row["reason"] == "bounty" and row["refId"].endswith(challenge["challengeId"])) == 1

    assert client.get("/parent/dashboard", headers=parent_headers).status_code == 200
    assert client.get("/parent/dashboard", headers=student_headers).status_code == 403


def test_shop_redeem_requires_full_address(client: TestClient) -> None:
    token = _register_and_login(client, f"shop{uuid.uuid4().hex[:8]}")
    headers = {"Authorization": f"Bearer {token}"}
    catalog = client.get("/shop/catalog", headers=headers).json()
    sku_id = catalog["items"][0]["skuId"]
    missing_address = client.post(
        "/shop/redeem",
        headers=headers,
        json={"skuId": sku_id, "address": {"name": "张三", "phone": "13800138000"}},
    )
    assert missing_address.status_code == 400
    assert "address" in missing_address.json()["detail"].lower()


def test_shop_redeem_does_not_overspend_on_duplicate_requests(client: TestClient) -> None:
    username = f"shopdup{uuid.uuid4().hex[:8]}"
    token = _register_and_login(client, username)
    headers = {"Authorization": f"Bearer {token}"}
    catalog = client.get("/shop/catalog", headers=headers).json()
    sku = catalog["items"][0]
    _grant_crystals(username, int(sku["crystalCost"]))
    payload = {
        "skuId": sku["skuId"],
        "address": {
            "name": "张三",
            "phone": "13800138000",
            "address": "北京市海淀区测试路 1 号",
        },
    }
    first = client.post("/shop/redeem", headers=headers, json=payload)
    assert first.status_code == 200, first.text
    second = client.post("/shop/redeem", headers=headers, json=payload)
    assert second.status_code == 400, second.text
    orders = client.get("/shop/orders", headers=headers).json()["orders"]
    assert len([row for row in orders if row["skuId"] == sku["skuId"]]) == 1
    assert client.get("/shop/catalog", headers=headers).json()["balance"] == 0


def test_gamification_me_and_leaderboard_filter_by_grade(client: TestClient) -> None:
    username = f"gr{uuid.uuid4().hex[:8]}"
    token = _register_and_login(client, username)
    headers = {"Authorization": f"Bearer {token}"}

    assert client.patch(
        "/learning/profile",
        headers=headers,
        json={"grade": "八年级"},
    ).status_code == 200

    _grant_power(username, "pep-g7-down-s9-2", 205)
    _grant_power(username, "pep-g8-down-s16-3", 405)

    me = client.get("/gamification/me", headers=headers)
    assert me.status_code == 200, me.text
    body = me.json()
    assert body["grade"] == "八年级"
    chapter_ids = {c["chapterId"] for c in body["chapters"]}
    assert "pep-g7-down-ch9" not in chapter_ids
    assert "pep-g8-down-ch16" in chapter_ids
    ch16 = next(c for c in body["chapters"] if c["chapterId"] == "pep-g8-down-ch16")
    assert ch16["powerScore"] == 405

    assert client.get(
        "/leaderboard?chapterId=pep-g7-down-ch9&scope=school",
        headers=headers,
    ).status_code == 400
    assert client.get(
        "/leaderboard?chapterId=pep-g8-down-ch16&scope=school",
        headers=headers,
    ).status_code == 200
    assert client.get(
        "/leaderboard?sectionId=pep-g8-down-s16-3&scope=school",
        headers=headers,
    ).status_code == 200


def test_gamification_me_sums_chapter_power(client: TestClient) -> None:
    username = f"gs{uuid.uuid4().hex[:8]}"
    token = _register_and_login(client, username)
    headers = {"Authorization": f"Bearer {token}"}

    assert client.patch(
        "/learning/profile",
        headers=headers,
        json={"grade": "八年级"},
    ).status_code == 200

    _grant_power(username, "pep-g8-down-s16-1", 10)
    _grant_power(username, "pep-g8-down-s16-2", 20)
    _grant_power(username, "pep-g8-down-s16-3", 30)

    me = client.get("/gamification/me", headers=headers).json()
    ch16 = next(c for c in me["chapters"] if c["chapterId"] == "pep-g8-down-ch16")
    assert ch16["powerScore"] == 10 + 20 + 30


def test_bounty_today_only_current_grade(client: TestClient) -> None:
    token = _register_and_login(client, f"bt{uuid.uuid4().hex[:8]}")
    headers = {"Authorization": f"Bearer {token}"}

    assert client.patch(
        "/learning/profile",
        headers=headers,
        json={"grade": "八年级"},
    ).status_code == 200

    today = client.get("/bounty/today", headers=headers)
    assert today.status_code == 200, today.text
    challenges = today.json()["challenges"]
    assert len(challenges) >= 1
    for item in challenges:
        section_id = item["sectionId"]
        assert section_id.startswith("pep-g8-"), section_id
        assert not section_id.startswith("pep-g7-"), section_id


def test_bounty_today_only_ninth_grade(client: TestClient) -> None:
    token = _register_and_login(client, f"b9{uuid.uuid4().hex[:8]}")
    headers = {"Authorization": f"Bearer {token}"}

    assert client.patch(
        "/learning/profile",
        headers=headers,
        json={"grade": "九年级"},
    ).status_code == 200

    today = client.get("/bounty/today", headers=headers)
    assert today.status_code == 200, today.text
    challenges = today.json()["challenges"]
    assert len(challenges) == 3
    for item in challenges:
        section_id = item["sectionId"]
        assert section_id.startswith("pep-g9-"), section_id
        assert not section_id.startswith("pep-g8-"), section_id


def test_replay_upload_rejects_idor_and_predictable_session_ids(client: TestClient) -> None:
    owner_token = _register_and_login(client, f"owner{uuid.uuid4().hex[:8]}")
    attacker_token = _register_and_login(client, f"attacker{uuid.uuid4().hex[:8]}")
    owner_headers = {"Authorization": f"Bearer {owner_token}"}
    attacker_headers = {"Authorization": f"Bearer {attacker_token}"}
    session_id = f"sess-{uuid.uuid4().hex}"
    payload = {
        "sessionId": session_id,
        "sectionId": "pep-g8-down-s16-3",
        "questionId": "q",
        "questionPrompt": "owner prompt",
        "inkTimeline": [{"tMs": 0, "points": []}],
        "turnsTimeline": [{"tMs": 10, "text": "好"}],
        "durationMs": 100,
    }
    assert client.post("/replays", headers=owner_headers, json=payload).status_code == 200
    hijack = client.post(
        "/replays",
        headers=attacker_headers,
        json={**payload, "questionPrompt": "evil overwrite"},
    )
    assert hijack.status_code == 403, hijack.text
    replay = client.get(f"/replays/{session_id}", headers=owner_headers)
    assert replay.status_code == 200, replay.text
    assert replay.json()["questionPrompt"] == "owner prompt"

    predictable = client.post(
        "/replays",
        headers=owner_headers,
        json={
            **payload,
            "sessionId": "sess-1770000000000-pep-g8-down-s16-3-q",
        },
    )
    assert predictable.status_code == 400
