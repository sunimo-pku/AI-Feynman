"""家长布置作业 API 测试。"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from fastapi.testclient import TestClient


def _register_student(client: TestClient, username: str | None = None) -> tuple[str, str]:
    username = username or f"stu{uuid.uuid4().hex[:10]}"
    password = "secret-pass-12345"
    resp = client.post(
        "/auth/register",
        json={"username": username, "password": password, "role": "student"},
    )
    assert resp.status_code == 200, resp.text
    return username, password


def _login(client: TestClient, username: str, password: str, *, parent_password: str | None = None) -> str:
    body: dict[str, str] = {"username": username, "password": password}
    if parent_password:
        body["parentPassword"] = parent_password
    resp = client.post("/auth/login", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()["token"]


def _register_parent(client: TestClient, child_username: str) -> tuple[str, str]:
    username = f"par{uuid.uuid4().hex[:10]}"
    password = "secret-pass-12345"
    parent_password = "parent-pass-12345"
    resp = client.post(
        "/auth/register",
        json={
            "username": username,
            "password": password,
            "role": "parent",
            "parentPassword": parent_password,
            "childUsername": child_username,
        },
    )
    assert resp.status_code == 200, resp.text
    token = _login(client, username, password, parent_password=parent_password)
    return token, password


def test_parent_assignment_catalog_flow(client: TestClient) -> None:
    child_user, child_pass = _register_student(client)
    parent_token, _ = _register_parent(client, child_user)
    student_token = _login(client, child_user, child_pass)

    due_at = (datetime.utcnow() + timedelta(days=1)).replace(microsecond=0).isoformat() + "Z"
    create = client.post(
        "/parent/assignments",
        headers={"Authorization": f"Bearer {parent_token}"},
        json={
            "sourceType": "catalog",
            "sectionId": "pep-g8-down-s16-1",
            "difficulty": 2,
            "title": "今晚巩固 16.1",
            "note": "重点讲取值范围",
            "dueAt": due_at,
        },
    )
    assert create.status_code == 200, create.text
    body = create.json()
    assert body["sectionId"] == "pep-g8-down-s16-1"
    assert body["status"] in ("pending", "in_progress")
    assignment_id = body["assignmentId"]
    question_id = body["questionId"]

    parent_list = client.get(
        "/parent/assignments",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert parent_list.status_code == 200
    assert parent_list.json()["pendingCount"] >= 1

    student_list = client.get(
        "/learning/assignments",
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert student_list.status_code == 200
    assert student_list.json()["pendingCount"] >= 1

    opened = client.post(
        f"/learning/assignments/{assignment_id}/open",
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert opened.status_code == 200
    assert opened.json()["status"] == "in_progress"

    review_id = f"{question_id}-{int(datetime.utcnow().timestamp() * 1000)}"
    sync = client.post(
        "/learning/progress/sync",
        headers={"Authorization": f"Bearer {student_token}"},
        json={
            "reviews": [
                {
                    "id": review_id,
                    "sectionId": "pep-g8-down-s16-1",
                    "questionId": question_id,
                    "questionPrompt": "测试题面",
                    "difficulty": 2,
                    "completedAt": datetime.utcnow().isoformat() + "Z",
                    "summary": "孩子讲清楚了取值范围",
                    "agentHighlights": ["能引用定义"],
                    "cautionPoints": ["别漏非负条件"],
                }
            ]
        },
    )
    assert sync.status_code == 200, sync.text

    detail = client.get(
        f"/parent/assignments/{assignment_id}",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert detail.status_code == 200, detail.text
    assert detail.json()["status"] == "completed"

    report = client.get(
        f"/parent/assignments/{assignment_id}/report",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert report.status_code == 200, report.text
    assert "取值范围" in report.json()["summary"]


def test_parent_custom_assignment(client: TestClient) -> None:
    child_user, child_pass = _register_student(client)
    parent_token, _ = _register_parent(client, child_user)
    student_token = _login(client, child_user, child_pass)

    due_at = (datetime.utcnow() + timedelta(hours=6)).replace(microsecond=0).isoformat() + "Z"
    create = client.post(
        "/parent/assignments",
        headers={"Authorization": f"Bearer {parent_token}"},
        json={
            "sourceType": "custom",
            "sectionId": "pep-g8-down-s16-2",
            "questionPrompt": r"化简 $\sqrt{12}$ 并说明每一步依据。",
            "dueAt": due_at,
        },
    )
    assert create.status_code == 200, create.text
    assert create.json()["sourceType"] == "custom"
    assert create.json()["questionId"].startswith("q-parent-")

    student_list = client.get(
        "/learning/assignments",
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert student_list.status_code == 200
    assert any(item["sourceType"] == "custom" for item in student_list.json()["active"])
