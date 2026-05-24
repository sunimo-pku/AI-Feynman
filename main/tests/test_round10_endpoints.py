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


def test_learning_sync_rejects_cross_student_review_client_id(
    client: TestClient,
) -> None:
    token_a = _register_and_login(client)
    token_b = _register_and_login(client)
    review_payload = {
        "progress": [],
        "reviews": [
            {
                "id": f"shared-review-{uuid.uuid4().hex[:8]}",
                "sectionId": "pep-g8-down-s16-3",
                "questionId": "q-s16-3-001",
                "questionPrompt": "化简 √12",
                "difficulty": 1,
                "tags": [],
                "completedAt": "2026-05-22T01:00:05",
                "summary": "student A summary",
                "agentHighlights": [],
                "cautionPoints": [],
            }
        ],
    }
    resp_a = client.post(
        "/learning/progress/sync",
        headers={"Authorization": f"Bearer {token_a}"},
        json=review_payload,
    )
    assert resp_a.status_code == 200, resp_a.text

    resp_b = client.post(
        "/learning/progress/sync",
        headers={"Authorization": f"Bearer {token_b}"},
        json={
            **review_payload,
            "reviews": [
                {
                    **review_payload["reviews"][0],
                    "summary": "student B should not overwrite",
                }
            ],
        },
    )
    assert resp_b.status_code == 403

    rows_b = client.get(
        "/learning/reviews",
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert rows_b.status_code == 200
    assert rows_b.json() == []


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
    # 教师建议应当与画像 primaryNextAction 一致
    profile_resp = client.get(
        "/parent/profile-insights",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert profile_resp.status_code == 200
    profile_body = profile_resp.json()
    assert body["suggestedNextAction"] == profile_body["primaryNextAction"]
    assert "16.2" in body["suggestedNextAction"] or "弱" in body["suggestedNextAction"]


def test_learning_profile_insights_explain_weakness_to_student_and_parent(
    client: TestClient,
    monkeypatch,
) -> None:
    monkeypatch.setattr(
        "app.services.learning_profile._generate_ai_refinement",
        lambda **kwargs: None,
    )
    child_name, child_password = _register_student(client)
    child_token = _login(client, child_name, child_password)
    headers = {"Authorization": f"Bearer {child_token}"}
    sync_resp = client.post(
        "/learning/progress/sync",
        headers=headers,
        json={
            "progress": [
                {
                    "sectionId": "pep-g8-down-s16-2",
                    "completedRounds": 2,
                    "masteryScore": 32,
                    "lastPracticedAt": "2026-05-22T02:01:00",
                    "lastSummary": "乘除法则前提条件还需要复讲。",
                }
            ],
            "reviews": [
                {
                    "id": f"profile-rev-{uuid.uuid4().hex[:8]}",
                    "sectionId": "pep-g8-down-s16-2",
                    "questionId": "q-s16-2-001",
                    "questionPrompt": "化简二次根式乘除",
                    "difficulty": 1,
                    "tags": ["二次根式乘除"],
                    "completedAt": "2026-05-22T02:02:00",
                    "summary": "需要说明 a,b≥0。",
                    "agentHighlights": [],
                    "cautionPoints": ["公式成立前先说明 a,b≥0"],
                }
            ],
        },
    )
    assert sync_resp.status_code == 200, sync_resp.text

    student_resp = client.get("/learning/profile-insights", headers=headers)
    assert student_resp.status_code == 200, student_resp.text
    body = student_resp.json()
    assert body["profileSource"] == "rules"
    assert body["aiSummary"] == ""
    assert body["dataPoints"] >= 2
    assert body["weakKnowledge"]
    assert "16.2" in body["weakKnowledge"][0]["title"]
    assert body["weakKnowledge"][0]["evidence"]
    assert body["learningTraits"]
    assert body["nextActions"]
    assert body["primaryNextAction"]
    assert body["recommendedSectionId"] == "pep-g8-down-s16-2"
    assert body["weakKnowledge"][0]["sectionId"] == "pep-g8-down-s16-2"

    _, _, parent_token = _register_parent(client, child_name)
    parent_resp = client.get(
        "/parent/profile-insights",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert parent_resp.status_code == 200, parent_resp.text
    parent_body = parent_resp.json()
    assert parent_body["weakKnowledge"][0]["title"] == body["weakKnowledge"][0]["title"]


def test_learning_profile_insights_can_apply_ai_refinement(
    client: TestClient,
    monkeypatch,
) -> None:
    child_name, child_password = _register_student(client)
    child_token = _login(client, child_name, child_password)
    headers = {"Authorization": f"Bearer {child_token}"}
    client.post(
        "/learning/progress/sync",
        headers=headers,
        json={
            "progress": [
                {
                    "sectionId": "pep-g8-down-s16-2",
                    "completedRounds": 2,
                    "masteryScore": 32,
                    "lastPracticedAt": "2026-05-22T02:01:00",
                    "lastSummary": "乘除法则前提条件还需要复讲。",
                }
            ],
            "reviews": [],
        },
    )

    def fake_refinement(**kwargs):
        return {
            "overview": "AI 观察到乘除法则前提条件需要优先复讲。",
            "aiSummary": "这名学生会算根式乘除，但讲解时容易先套公式、后补条件。",
            "learningTraits": [
                {
                    "title": "先算后补",
                    "description": "能跟上计算，但需要把公式成立条件前置说明。",
                    "evidence": [
                        {
                            "label": "掌握度",
                            "detail": "16.2 当前 32/100，已完成 2 轮讲题",
                        }
                    ],
                }
            ],
            "nextActions": ["下次讲根式乘除前，先说 a,b≥0。"],
        }

    monkeypatch.setattr(
        "app.services.learning_profile._generate_ai_refinement",
        fake_refinement,
    )

    resp = client.get("/learning/profile-insights", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["profileSource"] == "rules_ai"
    assert "先套公式" in body["aiSummary"]
    assert body["learningTraits"][0]["title"] == "先算后补"
    assert body["nextActions"][0] == "下次讲根式乘除前，先说 a,b≥0。"
    assert "先复讲" in body["primaryNextAction"]


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
    profile_resp = client.get(
        "/parent/profile-insights",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert profile_resp.status_code == 200
    assert body["teacherTip"] == profile_resp.json()["primaryNextAction"]


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
    captured: dict = {}

    def _fake_recognize(**kwargs):
        captured.update(kwargs)
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
            "questionPrompt": r"化简：$\sqrt{12}$",
            "sectionLabel": "二次根式的乘除",
            "knowledgeTags": ["二次根式", "化简"],
            "mode": "hwr",
            "referenceSteps": [r"$\sqrt{12}=2\sqrt{3}$", "标准答案不应进 prompt"],
            "boardImageBase64": tiny_png_b64,
            "steps": [
                {"stepId": "step_1", "strokeCount": 4},
            ],
        },
    )
    assert resp.status_code == 200
    assert "reference_hints" not in captured
    assert captured["question_prompt"] == r"化简：$\sqrt{12}$"
    assert captured["section_label"] == "二次根式的乘除"
    assert captured["knowledge_tags"] == ["二次根式", "化简"]
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
            "approved": True,
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
    progress = next(r for r in rows if r["sectionId"] == "pep-g8-down-s16-3")
    assert progress["completedRounds"] == 1
    assert progress["masteryScore"] == 10

    retry = client.post(
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
                }
            ],
            "roundIndex": 2,
            "history": [],
        },
    )
    assert retry.status_code == 200, retry.text
    rows_after_retry = client.get("/learning/progress", headers=headers).json()
    progress_after_retry = next(
        r for r in rows_after_retry if r["sectionId"] == "pep-g8-down-s16-3"
    )
    assert progress_after_retry["completedRounds"] == 1
    assert progress_after_retry["masteryScore"] == 10


def test_lecture_submit_completed_zero_delta_does_not_increment_progress(
    client: TestClient,
    monkeypatch,
) -> None:
    monkeypatch.setattr(
        "app.routers.lecture.generate_peer_assessments",
        lambda **_kwargs: {
            "status": "completed",
            "mastery_delta": 0,
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
            "text": "还需要再补充。",
            "highlight_step_ids": ["step_1"],
            "approved": True,
        },
    )
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}
    resp = client.post(
        "/lecture/submit",
        headers=headers,
        json={
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q-s16-3-002",
            "questionPrompt": "化简 √12",
            "studentSpeechText": "我说了过程",
            "steps": [
                {
                    "stepId": "step_1",
                    "latex": r"\sqrt{12} = 2\sqrt{3}",
                    "plainText": "根号12=2根号3",
                    "strokeCount": 5,
                    "boundingBox": {"x": 0, "y": 0, "width": 10, "height": 10},
                }
            ],
            "roundIndex": 1,
            "history": [],
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["masteryDelta"] == 0
    resp_p = client.get("/learning/progress", headers=headers)
    assert resp_p.status_code == 200
    assert resp_p.json() == []


def test_lecture_submit_without_llm_key_returns_502(client: TestClient, monkeypatch) -> None:
    from app.services.lecture_agent import LectureAgentError

    def fail_peer_assessment(**_kwargs):
        raise LectureAgentError("DEEPSEEK_API_KEY is not configured")

    monkeypatch.setattr(
        "app.routers.lecture.generate_peer_assessments",
        fail_peer_assessment,
    )
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
