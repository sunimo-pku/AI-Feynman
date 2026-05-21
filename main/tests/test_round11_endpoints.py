from __future__ import annotations

import uuid
import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).parent))
from test_round10_endpoints import _register_and_login


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
    assert client.get("/parent/replays", headers=headers).status_code == 200
    assert client.post("/knowledge/search", json={"query": "同类二次根式"}).status_code == 200


def test_bounty_and_children_binding(client: TestClient) -> None:
    parent_token = _register_and_login(client, f"parent{uuid.uuid4().hex[:6]}")
    child_name = f"child{uuid.uuid4().hex[:6]}"
    _register_and_login(client, child_name)
    headers = {"Authorization": f"Bearer {parent_token}"}
    resp = client.post("/parent/children/bind", headers=headers, json={"username": child_name})
    assert resp.status_code == 200, resp.text
    assert client.get("/parent/children", headers=headers).json()["children"]

    today = client.get("/bounty/today").json()["challenges"][0]
    resp = client.post(
        "/bounty/submit",
        headers=headers,
        json={
            "challengeId": today["challengeId"],
            "circledBox": today["errorBox"],
            "transcriptText": "这里条件写错了。",
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["completed"] is True
