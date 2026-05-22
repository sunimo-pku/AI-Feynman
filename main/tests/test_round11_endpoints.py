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


def test_profile_reviews_gamification_shop_replay_knowledge(client: TestClient) -> None:
    token = _register_and_login(client, f"r11{uuid.uuid4().hex[:8]}")
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
    assert resp.status_code == 200, resp.text
    assert resp.json()["powerScore"] > 0

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
    answers = [
        {"stepId": q["stepId"], "optionId": q["correctOptionId"]}
        for q in quizzes
    ]
    submit = client.post(
        "/bounty/submit",
        headers=student_headers,
        json={
            "challengeId": challenge["challengeId"],
            "stepAnswers": answers,
            "transcriptText": "因为被开方数要非负，所以 x-3 要大于等于 0，x 要大于等于 3。",
        },
    )
    assert submit.status_code == 200
    body = submit.json()
    assert body["mcqCorrect"] is True
    assert body["explanationScore"] >= 60

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


def test_gamification_me_and_leaderboard_filter_by_grade(client: TestClient) -> None:
    token = _register_and_login(client, f"gr{uuid.uuid4().hex[:8]}")
    headers = {"Authorization": f"Bearer {token}"}

    assert client.patch(
        "/learning/profile",
        headers=headers,
        json={"grade": "八年级"},
    ).status_code == 200

    for section_id, mastery in [("pep-g7-down-s9-2", 20), ("pep-g8-down-s16-3", 40)]:
        resp = client.post(
            "/gamification/power/adjust",
            headers=headers,
            json={
                "sectionId": section_id,
                "masteryScore": mastery,
                "completedRounds": 1,
                "bountyWins": 0,
            },
        )
        assert resp.status_code == 200, resp.text

    me = client.get("/gamification/me", headers=headers)
    assert me.status_code == 200, me.text
    body = me.json()
    assert body["grade"] == "八年级"
    section_ids = {s["sectionId"] for s in body["sections"]}
    assert "pep-g7-down-s9-2" not in section_ids
    assert "pep-g8-down-s16-3" in section_ids

    assert client.get(
        "/leaderboard?sectionId=pep-g7-down-s9-2&scope=school",
        headers=headers,
    ).status_code == 400
    assert client.get(
        "/leaderboard?sectionId=pep-g8-down-s16-3&scope=school",
        headers=headers,
    ).status_code == 200


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
