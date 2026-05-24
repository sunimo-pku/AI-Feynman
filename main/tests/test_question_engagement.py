"""题目收藏与家长反馈接口测试。"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).parent))
from test_round10_endpoints import (
    DEFAULT_PARENT_PASSWORD,
    _login,
    _register_parent,
    _register_student,
)


def _student_headers(client: TestClient, username: str | None = None) -> dict[str, str]:
    username, password = _register_student(client, username)
    token = _login(client, username, password)
    return {"Authorization": f"Bearer {token}"}


def _parent_headers(
    client: TestClient,
    child_username: str,
    child_password: str = "secret-pass-12345",
) -> dict[str, str]:
    _, _, token = _register_parent(
        client,
        child_username,
        child_password,
        parent_password=DEFAULT_PARENT_PASSWORD,
    )
    return {"Authorization": f"Bearer {token}"}


def test_favorites_crud(client: TestClient) -> None:
    headers = _student_headers(client)
    qid = f"q-{uuid.uuid4().hex[:8]}"
    sid = "pep-g8-down-s16-1"

    empty = client.get("/learning/favorites", headers=headers)
    assert empty.status_code == 200
    assert empty.json()["favorites"] == []

    put = client.put(
        "/learning/favorites",
        headers=headers,
        json={
            "questionId": qid,
            "sectionId": sid,
            "questionPrompt": r"化简 $\sqrt{12}$",
            "difficulty": 2,
            "favorited": True,
        },
    )
    assert put.status_code == 200, put.text
    body = put.json()
    assert body["questionId"] == qid
    assert body["sectionId"] == sid
    assert body["difficulty"] == 2

    listed = client.get("/learning/favorites", headers=headers)
    assert listed.status_code == 200
    favs = listed.json()["favorites"]
    assert len(favs) == 1
    assert favs[0]["questionId"] == qid

    deleted = client.delete(f"/learning/favorites/{qid}", headers=headers)
    assert deleted.status_code == 204

    after = client.get("/learning/favorites", headers=headers)
    assert after.status_code == 200
    assert after.json()["favorites"] == []


def test_question_feedback_student_to_parent(client: TestClient) -> None:
    child_user, child_pass = _register_student(client)
    student_headers = {
        "Authorization": f"Bearer {_login(client, child_user, child_pass)}",
    }
    parent_headers = _parent_headers(client, child_user, child_pass)

    qid = f"q-{uuid.uuid4().hex[:8]}"
    sid = "pep-g8-down-s16-2"
    note = "根号化简总是忘记因式分解"

    post = client.post(
        "/learning/question-feedback",
        headers=student_headers,
        json={
            "questionId": qid,
            "sectionId": sid,
            "questionPrompt": r"计算 $\sqrt{18}$",
            "note": note,
            "difficulty": 1,
        },
    )
    assert post.status_code == 201, post.text
    created = post.json()
    assert created["questionId"] == qid
    assert created["note"] == note

    parent_list = client.get("/parent/question-feedback", headers=parent_headers)
    assert parent_list.status_code == 200, parent_list.text
    rows = parent_list.json()
    assert len(rows) >= 1
    match = next(r for r in rows if r["questionId"] == qid)
    assert match["note"] == note
    assert match["sectionId"] == sid
    assert match["studentName"]


def test_question_feedback_requires_student(client: TestClient) -> None:
    child_user, child_pass = _register_student(client)
    parent_headers = _parent_headers(client, child_user, child_pass)

    resp = client.post(
        "/learning/question-feedback",
        headers=parent_headers,
        json={
            "questionId": "q-test",
            "sectionId": "pep-g8-down-s16-1",
            "questionPrompt": "test",
            "note": "hello",
        },
    )
    assert resp.status_code == 403


def test_parent_feedback_requires_parent(client: TestClient) -> None:
    headers = _student_headers(client)
    resp = client.get("/parent/question-feedback", headers=headers)
    assert resp.status_code == 403
