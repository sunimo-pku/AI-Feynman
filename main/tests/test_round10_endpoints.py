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


def _register_and_login(client: TestClient, username: str | None = None) -> str:
    username = username or f"u{uuid.uuid4().hex[:10]}"
    password = "secret-pass-12345"
    resp = client.post(
        "/auth/register",
        json={"username": username, "password": password},
    )
    assert resp.status_code == 200, resp.text
    resp = client.post(
        "/auth/login",
        json={"username": username, "password": password},
    )
    assert resp.status_code == 200
    return resp.json()["token"]


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


def test_parent_dashboard_requires_auth(client: TestClient) -> None:
    resp = client.get("/parent/dashboard")
    assert resp.status_code == 401


def test_parent_dashboard_basic_fields(client: TestClient) -> None:
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}
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
    resp = client.get("/parent/dashboard", headers=headers)
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
    token = _register_and_login(client)
    headers = {"Authorization": f"Bearer {token}"}
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
    resp = client.get("/parent/poster", headers=headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["weekCompletedRounds"] >= 1
    assert body["highestScore"] >= 0
    assert "teacherTip" in body


# ------------------------------------------------------------------ #
# /ocr
# ------------------------------------------------------------------ #


def test_ocr_ink_returns_latex_for_each_step(client: TestClient) -> None:
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g8-down-s16-3",
            "questionId": "q-s16-3-001",
            "referenceSteps": [
                r"$\sqrt{12} = 2\sqrt{3}$",
                r"$\sqrt{27} = 3\sqrt{3}$",
                r"$2\sqrt{3} - 3\sqrt{3} = -\sqrt{3}$",
            ],
            "steps": [
                {"stepId": "step_1", "strokeCount": 5},
                {"stepId": "step_2", "strokeCount": 5},
                {"stepId": "step_3", "strokeCount": 4},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["steps"]) == 3
    assert body["steps"][0]["stepId"] == "step_1"
    assert body["steps"][0]["latex"]  # 非空
    assert body["steps"][0]["confidence"] > 0
    # plainText 经过粗翻译应当含「根号」
    assert "根号" in body["steps"][0]["plainText"]


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
    monkeypatch.setattr("app.routers.ocr.Config.OCR_HWR_API_KEY", "ci-key")
    resp = client.post(
        "/ocr/ink",
        json={
            "sectionId": "pep-g9-up-s22-1",
            "questionId": "q-function",
            "mode": "hwr",
            "referenceSteps": [],
            "steps": [
                {"stepId": "step_1", "strokeCount": 3, "imageBase64": "abc"},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["steps"][0]["latex"] == ""
    assert body["steps"][0]["plainText"] == ""
    assert body["steps"][0]["confidence"] == 0.0


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
        "app.routers.lecture.generate_lecture_turns",
        lambda **_kwargs: {
            "status": "completed",
            "mastery_delta": 1,
            "turns": [
                {
                    "turn_id": "turn_1",
                    "role": "teacher",
                    "display_name": "李老师",
                    "text": "这次解释清楚了。",
                    "highlight_step_ids": ["step_1"],
                }
            ],
            "source": "llm",
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
    monkeypatch.setattr("app.services.lecture_agent.Config.DEEPSEEK_API_KEY", "")
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
    assert "Lecture agent failed" in resp.json()["detail"]
