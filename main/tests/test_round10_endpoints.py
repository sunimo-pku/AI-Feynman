"""第十轮新增 HTTP 路由端到端测试。

覆盖：
- POST /auth/register + login → 拿到 token
- GET /learning/progress 401 / 200
- POST /learning/progress/sync 合并 + 幂等
- GET /parent/dashboard 字段完整
- POST /ocr/ink 规则匹配
- POST /lecture/submit 带 token → 持久化进度
"""

from __future__ import annotations

import uuid
from datetime import datetime

from fastapi.testclient import TestClient


DEFAULT_PARENT_PASSWORD = "parent-pass-12345"


def _register_student(
    client: TestClient,
    username: str | None = None,
    password: str = "secret-pass-12345",
    parent_password: str = DEFAULT_PARENT_PASSWORD,
) -> tuple[str, str]:
    username = username or f"stu{uuid.uuid4().hex[:10]}"
    resp = client.post(
        "/auth/register",
        json={
            "username": username,
            "password": password,
            "parentPassword": parent_password,
            "grade": "八年级",
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


def _register_and_login(client: TestClient, username: str | None = None) -> str:
    username, password = _register_student(client, username)
    return _login(client, username, password)


def _register_parent(
    client: TestClient,
    account_username: str,
    account_password: str = "secret-pass-12345",
    parent_password: str = DEFAULT_PARENT_PASSWORD,
) -> tuple[str, str, str]:
    token = _login(
        client,
        account_username,
        account_password,
        login_as="parent",
        parent_password=parent_password,
    )
    return account_username, account_password, token


# ------------------------------------------------------------------ #
# /learning
# ------------------------------------------------------------------ #


def test_learning_progress_requires_auth(client: TestClient) -> None:
    resp = client.get("/learning/progress")
    assert resp.status_code == 401


def test_learning_progress_empty_for_new_user(client: TestClient) -> None:
    token = _register_and_login(client)
    resp = client.get(
        "/learning/progress",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json() == []


def test_learning_sync_merges_and_is_idempotent(client: TestClient) -> None:
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}

    payload = {
        "progress": [
            {
                "sectionId": "pep-g8-down-s16-3",
                "completedRounds": 2,
                "masteryScore": 24,
                "lastPracticedAt": "2026-05-22T01:00:00",
                "lastSummary": "搞清楚了 √12=2√3 的拆分前提。",
            }
        ],
        "reviews": [
            {
                "id": "q-s16-3-001-1770000000000",
                "sectionId": "pep-g8-down-s16-3",
                "questionId": "q-s16-3-001",
                "questionPrompt": "化简 √12 - √27",
                "difficulty": 1,
                "tags": ["最简二次根式"],
                "completedAt": "2026-05-22T01:00:05",
                "summary": "本题讲清楚了同类二次根式合并的前提。",
                "agentHighlights": ["小明追问 4 为什么能开出来"],
                "cautionPoints": ["先化最简二次根式"],
            }
        ],
    }
    resp = client.post(
        "/learning/progress/sync",
        headers=headers,
        json=payload,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["acceptedProgress"] == 1
    assert body["acceptedReviews"] == 1
    assert len(body["progress"]) == 1
    assert body["progress"][0]["masteryScore"] == 24
    assert len(body["reviews"]) == 1

    # 第二次重发同样的 payload —— 应该幂等：accepted 计数允许为 0 或 1
    # （progress 没字段升高时 accepted=0；review 已存在 id 也是 0），
    # 但仓库内行数仍然只有 1 条。
    resp2 = client.post(
        "/learning/progress/sync",
        headers=headers,
        json=payload,
    )
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert len(body2["progress"]) == 1
    assert len(body2["reviews"]) == 1

    # 第三次：把 masteryScore 提到 36，应当被 accept
    payload2 = dict(payload)
    payload2["progress"] = [
        {
            **payload["progress"][0],
            "masteryScore": 36,
            "completedRounds": 3,
            "lastPracticedAt": "2026-05-22T03:00:00",
        }
    ]
    payload2["reviews"] = []
    resp3 = client.post(
        "/learning/progress/sync",
        headers=headers,
        json=payload2,
    )
    assert resp3.status_code == 200
    body3 = resp3.json()
    assert body3["acceptedProgress"] == 1
    assert body3["progress"][0]["masteryScore"] == 36
    assert body3["progress"][0]["completedRounds"] == 3


def test_learning_reviews_can_filter_by_section(client: TestClient) -> None:
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}
    payload = {
        "progress": [],
        "reviews": [
            {
                "id": f"rev-1-{uuid.uuid4().hex[:6]}",
                "sectionId": "pep-g8-down-s16-1",
                "questionId": "q-s16-1-001",
                "questionPrompt": "p1",
                "difficulty": 1,
                "tags": [],
                "completedAt": "2026-05-22T00:00:00",
                "summary": "s1",
                "agentHighlights": [],
                "cautionPoints": [],
            },
            {
                "id": f"rev-2-{uuid.uuid4().hex[:6]}",
                "sectionId": "pep-g8-down-s16-2",
                "questionId": "q-s16-2-001",
                "questionPrompt": "p2",
                "difficulty": 2,
                "tags": [],
                "completedAt": "2026-05-22T00:01:00",
                "summary": "s2",
                "agentHighlights": [],
                "cautionPoints": [],
            },
        ],
    }
    resp = client.post(
        "/learning/progress/sync",
        headers=headers,
        json=payload,
    )
    assert resp.status_code == 200

    resp = client.get(
        "/learning/reviews?sectionId=pep-g8-down-s16-2",
        headers=headers,
    )
    assert resp.status_code == 200
    rows = resp.json()
    assert len(rows) == 1
    assert rows[0]["sectionId"] == "pep-g8-down-s16-2"


# ------------------------------------------------------------------ #
# /parent
# ------------------------------------------------------------------ #


def test_parent_login_session_role(client: TestClient) -> None:
    child_name, child_password = _register_student(
        client, f"parent-role{uuid.uuid4().hex[:6]}"
    )
    resp = client.post(
        "/auth/login",
        json={
            "username": child_name,
            "password": child_password,
            "loginAs": "parent",
            "parentPassword": DEFAULT_PARENT_PASSWORD,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["sessionRole"] == "parent"
    assert body["user"]["role"] == "parent"


def test_switch_parent_requires_student_session(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    student_token = _login(client, child_name, child_password)
    resp = client.post(
        "/auth/switch-parent",
        json={"parentPassword": DEFAULT_PARENT_PASSWORD},
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["sessionRole"] == "parent"
    parent_token = body["token"]
    assert parent_token != student_token

    me = client.get(
        "/auth/me",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert me.status_code == 200
    assert me.json()["role"] == "parent"


def test_switch_parent_wrong_password(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    student_token = _login(client, child_name, child_password)
    resp = client.post(
        "/auth/switch-parent",
        json={"parentPassword": "wrong-parent-pass"},
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert resp.status_code == 401


def test_switch_parent_forbidden_from_parent_session(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    _, _, parent_token = _register_parent(client, child_name, child_password)
    resp = client.post(
        "/auth/switch-parent",
        json={"parentPassword": DEFAULT_PARENT_PASSWORD},
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 403


def test_switch_student_from_parent_session(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    _, _, parent_token = _register_parent(client, child_name, child_password)
    resp = client.post(
        "/auth/switch-student",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["sessionRole"] == "student"
    student_token = body["token"]
    dash = client.get(
        "/parent/dashboard",
        headers={"Authorization": f"Bearer {student_token}"},
    )
    assert dash.status_code == 403


def test_parent_dashboard_requires_auth(client: TestClient) -> None:
    resp = client.get("/parent/dashboard")
    assert resp.status_code == 401


def test_parent_dashboard_student_forbidden(client: TestClient) -> None:
    token = _register_and_login(client)
    resp = client.get("/parent/dashboard", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 403


def test_parent_dashboard_basic_fields(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    child_token = _login(client, child_name, child_password)
    headers = {"Authorization": f"Bearer {child_token}"}
    # 先同步几条进度，让 dashboard 有内容
    client.post(
        "/learning/progress/sync",
        headers=headers,
        json={
            "progress": [
                {
                    "sectionId": "pep-g8-down-s16-1",
                    "completedRounds": 3,
                    "masteryScore": 72,
                    "lastPracticedAt": "2026-05-22T02:00:00",
                    "lastSummary": "ok",
                },
                {
                    "sectionId": "pep-g8-down-s16-2",
                    "completedRounds": 1,
                    "masteryScore": 24,
                    "lastPracticedAt": "2026-05-22T02:01:00",
                    "lastSummary": "弱",
                },
            ],
            "reviews": [],
        },
    )
    _, _, parent_token = _register_parent(client, child_name)
    resp = client.get(
        "/parent/dashboard",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "studentName" in body
    assert "overallMastery" in body
    assert isinstance(body["weakSections"], list)
    assert isinstance(body["recentReviews"], list)
    # 16.2 是弱项（24 < 60）
    weak_ids = [w["sectionId"] for w in body["weakSections"]]
    assert "pep-g8-down-s16-2" in weak_ids
    # 16.1 应在 strongSections
    strong_ids = [s["sectionId"] for s in body["strongSections"]]
    assert "pep-g8-down-s16-1" in strong_ids
    # 教师建议应当点名弱项
    assert "16.2" in body["suggestedNextAction"] or "弱" in body["suggestedNextAction"]


def test_parent_poster_includes_week_stats(client: TestClient) -> None:
    child_name, child_password = _register_student(client)
    child_token = _login(client, child_name, child_password)
    headers = {"Authorization": f"Bearer {child_token}"}
    client.post(
        "/learning/progress/sync",
        headers=headers,
        json={
            "progress": [
                {
                    "sectionId": "pep-g8-down-s16-3",
                    "completedRounds": 2,
                    "masteryScore": 36,
                    "lastPracticedAt": datetime.utcnow().isoformat(),
                    "lastSummary": "搞清楚了 √12=2√3",
                }
            ],
            "reviews": [
                {
                    "id": f"rev-{uuid.uuid4().hex[:8]}",
                    "sectionId": "pep-g8-down-s16-3",
                    "questionId": "q-s16-3-001",
                    "questionPrompt": "p",
                    "difficulty": 1,
                    "tags": [],
                    "completedAt": datetime.utcnow().isoformat(),
                    "summary": "s",
                    "agentHighlights": [],
                    "cautionPoints": [],
                }
            ],
        },
    )
    _, _, parent_token = _register_parent(client, child_name)
    resp = client.get(
        "/parent/poster",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["weekCompletedRounds"] >= 1
    assert body["highestScore"] >= 0
    assert "teacherTip" in body


# ------------------------------------------------------------------ #
# /ocr
# ------------------------------------------------------------------ #


def test_ocr_ink_does_not_fabricate_from_reference_steps(
    client: TestClient,
) -> None:
    """referenceSteps 是解题框架，不能当成学生 OCR 结果回填。"""
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q-s16-3-001",
            "referenceSteps": [
                "写出已知",
                "列出关键步骤",
                r"$\sqrt{12} = 2\sqrt{3}$",
            ],
            "steps": [
                {"stepId": "step_1", "strokeCount": 5},
                {"stepId": "step_2", "strokeCount": 5},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["steps"]) == 2
    for step in body["steps"]:
        assert step["latex"] == ""
        assert step["plainText"] == ""
        assert step["source"] == "empty"
        assert step["confidence"] == 0.0


def test_ocr_ink_without_reference_does_not_invent_latex(client: TestClient) -> None:
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g8-down-s16-2",
            "questionId": "q-s16-2-001",
            "referenceSteps": [],
            "steps": [
                {"stepId": "step_1", "strokeCount": 3},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["steps"]) == 1
    assert body["steps"][0]["latex"] == ""
    assert body["steps"][0]["plainText"] == ""
    assert body["steps"][0]["source"] == "empty"


def test_ocr_hwr_without_reference_does_not_invent_radical(
    client: TestClient,
    monkeypatch,
) -> None:
    """无效/过小 boardImageBase64 时 Qwen-VL 不调用，也不编造 LaTeX。"""
    monkeypatch.setattr("app.routers.ocr.Config.ALIYUN_API_KEY", "ci-key")
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g9-up-s22-1",
            "questionId": "q-function",
            "mode": "hwr",
            "referenceSteps": [],
            "boardImageBase64": "abc",
            "steps": [
                {"stepId": "step_1", "strokeCount": 3},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["steps"][0]["latex"] == ""
    assert body["steps"][0]["plainText"] == ""
    assert body["board"]["latex"] == ""
    assert body["board"]["plainText"] == ""
    assert body["board"]["confidence"] == 0.0
    assert body["board"]["source"] == "empty"


def test_ocr_hwr_qwen_vl_returns_recognized_latex(
    client: TestClient,
    monkeypatch,
) -> None:
    tiny_png_b64 = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
        "z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
    monkeypatch.setattr("app.routers.ocr.Config.ALIYUN_API_KEY", "ci-key")

    def _fake_recognize(**_kwargs):
        return {
            "latex": r"\sqrt{12}=2\sqrt{3}",
            "plainText": "根号12等于2倍根号3",
            "confidence": 0.82,
            "source": "qwen_vl",
        }

    monkeypatch.setattr("app.routers.ocr.recognize_ink_board", _fake_recognize)
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g8-down-s16-1",
            "questionId": "q-s16-1-001",
            "mode": "hwr",
            "referenceSteps": ["写出已知"],
            "boardImageBase64": tiny_png_b64,
            "steps": [
                {"stepId": "step_1", "strokeCount": 4},
            ],
        },
    )
    assert resp.status_code == 200
    board = resp.json()["board"]
    assert board["latex"] == r"\sqrt{12}=2\sqrt{3}"
    assert "根号" in board["plainText"]
    assert board["confidence"] >= 0.5
    assert board["source"] == "qwen_vl"
    assert board["mode"] == "hwr"
    assert resp.json()["steps"][0]["latex"] == ""


def test_tts_error_returns_502(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr(
        "app.routers.tts.synthesize",
        lambda _text, _speaker: {"error": "tts failed"},
    )
    resp = client.post("/tts", json={"text": "测试", "role": "teacher"})
    assert resp.status_code == 502
    assert resp.json()["detail"] == "tts failed"


# ------------------------------------------------------------------ #
# /lecture/submit + auth → progress 自动落库
# ------------------------------------------------------------------ #


def test_lecture_submit_with_auth_persists_progress(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr(
        "app.routers.lecture.generate_peer_assessments",
        lambda **_kwargs: {
            "status": "completed",
            "mastery_delta": 1,
            "all_understood": True,
            "assessments": [
                {
                    "role": "xiaoming",
                    "display_name": "小明",
                    "understood": True,
                    "reason": "听懂了",
                    "highlight_step_ids": ["step_1"],
                },
                {
                    "role": "daxiong",
                    "display_name": "大雄",
                    "understood": True,
                    "reason": "听懂了",
                    "highlight_step_ids": ["step_1"],
                },
                {
                    "role": "monitor",
                    "display_name": "班长",
                    "understood": True,
                    "reason": "听懂了",
                    "highlight_step_ids": ["step_1"],
                },
            ],
            "source": "llm",
        },
    )
    monkeypatch.setattr(
        "app.routers.lecture.generate_teacher_summary",
        lambda **_kwargs: {
            "turn_id": "summary_1",
            "role": "teacher",
            "display_name": "李老师",
            "text": "这次解释清楚了。",
            "highlight_step_ids": ["step_1"],
        },
    )
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}
    resp = client.post(
        "/lecture/submit",
        headers=headers,
        json={
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q-s16-3-001",
            "questionPrompt": "化简 √12 - √27",
            "studentSpeechText": "我把 12 拆成 4×3，27 拆成 9×3",
            "steps": [
                {
                    "stepId": "step_1",
                    "latex": r"\sqrt{12} = 2\sqrt{3}",
                    "plainText": "根号12=2根号3",
                    "strokeCount": 5,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                },
                {
                    "stepId": "step_2",
                    "latex": r"\sqrt{27} = 3\sqrt{3}",
                    "plainText": "根号27=3根号3",
                    "strokeCount": 5,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                },
            ],
            "roundIndex": 2,
            "history": [
                {
                    "role": "student",
                    "displayName": "我",
                    "text": "之前没说为什么 4 能开出来",
                    "highlightStepIds": ["step_1"],
                },
                {
                    "role": "teacher",
                    "displayName": "李老师",
                    "text": "你能不能说说为什么 4 可以从根号里出来？",
                    "highlightStepIds": ["step_1"],
                },
            ],
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "completed"
    resp_p = client.get("/learning/progress", headers=headers)
    assert resp_p.status_code == 200
    rows = resp_p.json()
    section_ids = [r["sectionId"] for r in rows]
    assert "pep-g8-down-s16-3" in section_ids


def test_lecture_submit_without_llm_key_returns_502(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr("app.services.peer_assessment_agent.Config.DEEPSEEK_API_KEY", "")
    resp = client.post(
        "/lecture/submit",
        json={
            "sectionId": "pep-g8-down-s16-1",
            "questionId": "q-s16-1-001",
            "questionPrompt": "p",
            "studentSpeechText": "",
            "steps": [
                {
                    "stepId": "step_1",
                    "latex": "",
                    "plainText": "",
                    "strokeCount": 1,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                }
            ],
            "roundIndex": 1,
            "history": [],
        },
    )
    assert resp.status_code == 502
    assert "Peer assessment failed" in resp.json()["detail"]
