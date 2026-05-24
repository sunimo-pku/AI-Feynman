"""家长布置作业 API 测试。"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from fastapi.testclient import TestClient


DEFAULT_PARENT_PASSWORD = "parent-pass-12345"


def _register_student(client: TestClient, username: str | None = None) -> tuple[str, str]:
    username = username or f"stu{uuid.uuid4().hex[:10]}"
    password = "secret-pass-12345"
    resp = client.post(
        "/auth/register",
        json={
            "username": username,
            "password": password,
            "parentPassword": DEFAULT_PARENT_PASSWORD,
            "grade": "八年级",
        },
    )
    assert resp.status_code == 200, resp.text
    return username, password


def _register_student_with_grade(
    client: TestClient,
    grade: str,
    username: str | None = None,
) -> tuple[str, str]:
    username = username or f"stu{uuid.uuid4().hex[:10]}"
    password = "secret-pass-12345"
    resp = client.post(
        "/auth/register",
        json={
            "username": username,
            "password": password,
            "parentPassword": DEFAULT_PARENT_PASSWORD,
            "grade": grade,
        },
    )
    assert resp.status_code == 200, resp.text
    return username, password


def _login(
    client: TestClient,
    username: str,
    password: str,
    *,
    login_as: str = "student",
    parent_password: str | None = None,
) -> str:
    body: dict[str, str] = {
        "username": username,
        "password": password,
        "loginAs": login_as,
    }
    if parent_password:
        body["parentPassword"] = parent_password
    resp = client.post("/auth/login", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()["token"]


def _register_parent(client: TestClient, account_username: str) -> tuple[str, str]:
    password = "secret-pass-12345"
    token = _login(
        client,
        account_username,
        password,
        login_as="parent",
        parent_password=DEFAULT_PARENT_PASSWORD,
    )
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


def test_parent_assignment_rejects_cross_grade_section(client: TestClient) -> None:
    child_user, _ = _register_student_with_grade(client, "七年级")
    parent_token, _ = _register_parent(client, child_user)

    due_at = (datetime.utcnow() + timedelta(hours=6)).replace(microsecond=0).isoformat() + "Z"
    create = client.post(
        "/parent/assignments",
        headers={"Authorization": f"Bearer {parent_token}"},
        json={
            "sourceType": "catalog",
            "sectionId": "pep-g8-down-s16-1",
            "difficulty": 1,
            "dueAt": due_at,
        },
    )
    assert create.status_code == 400, create.text
    assert "linked child's grade" in create.json()["detail"]

    rec = client.get(
        "/parent/assignments/recommendations",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert rec.status_code == 200, rec.text
    assert rec.json()["recommendations"]
    assert all(
        item["sectionId"].startswith("pep-g7-")
        for item in rec.json()["recommendations"]
    )


def test_parent_assignment_recommendations(client: TestClient) -> None:
    child_user, child_pass = _register_student(client)
    parent_token, _ = _register_parent(client, child_user)
    student_token = _login(client, child_user, child_pass)

    # 无学习记录时应有 starter 推荐
    empty = client.get(
        "/parent/assignments/recommendations",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert empty.status_code == 200, empty.text
    body = empty.json()
    assert body["count"] >= 1
    assert body["recommendations"][0]["questionId"]

    # 同步弱项 + 易错回顾
    sync = client.post(
        "/learning/progress/sync",
        headers={"Authorization": f"Bearer {student_token}"},
        json={
            "progress": [
                {
                    "sectionId": "pep-g8-down-s16-1",
                    "masteryScore": 20,
                    "completedRounds": 2,
                    "lastPracticedAt": datetime.utcnow().isoformat() + "Z",
                }
            ],
            "reviews": [
                {
                    "id": f"q-s16-1-kp2-005-{int(datetime.utcnow().timestamp() * 1000)}",
                    "sectionId": "pep-g8-down-s16-1",
                    "questionId": "q-s16-1-kp2-005",
                    "questionPrompt": r"要使 $\sqrt{x-3}+\dfrac{1}{x-4}$ 有意义，x 应满足什么条件？",
                    "difficulty": 2,
                    "completedAt": datetime.utcnow().isoformat() + "Z",
                    "summary": "基本讲清楚",
                    "agentHighlights": [],
                    "cautionPoints": ["移项时别漏变号"],
                }
            ],
        },
    )
    assert sync.status_code == 200, sync.text

    rec = client.get(
        "/parent/assignments/recommendations",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert rec.status_code == 200, rec.text
    items = rec.json()["recommendations"]
    assert any(i.get("reasonType") == "mistake_review" for i in items)

    due_at = (datetime.utcnow() + timedelta(days=1)).replace(microsecond=0).isoformat() + "Z"
    picked = next(i for i in items if i.get("questionId"))
    create = client.post(
        "/parent/assignments",
        headers={"Authorization": f"Bearer {parent_token}"},
        json={
            "sourceType": "catalog",
            "sectionId": picked["sectionId"],
            "questionId": picked["questionId"],
            "difficulty": picked["difficulty"],
            "dueAt": due_at,
        },
    )
    assert create.status_code == 200, create.text
    assert create.json()["questionId"] == picked["questionId"]
