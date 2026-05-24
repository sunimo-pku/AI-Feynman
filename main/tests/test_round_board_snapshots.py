"""各轮白板 OCR 摘要归档与 prompt 注入。"""

from __future__ import annotations

from app.services.lecture_agent import (
    _build_user_prompt,
    _sanitize_round_board_snapshots,
)


def test_sanitize_round_board_snapshots_keeps_prior_rounds_only() -> None:
    raw = [
        {"roundIndex": 1, "boardPlainText": "第一轮", "strokeCount": 3},
        {"roundIndex": 2, "boardPlainText": "第二轮", "strokeCount": 5},
        {"roundIndex": 3, "boardPlainText": "当前轮不应出现", "strokeCount": 1},
    ]
    cleaned = _sanitize_round_board_snapshots(raw, current_round=3)
    assert [item["round_index"] for item in cleaned] == [1, 2]
    assert cleaned[0]["board_plain_text"] == "第一轮"


def test_build_user_prompt_includes_prior_round_boards_for_peer() -> None:
    prompt = _build_user_prompt(
        section_id="pep-g8-down-s16-1",
        question_id="q1",
        question_prompt="化简根号十二",
        student_speech_text="我补充一下",
        steps=[
            {
                "stepId": "board",
                "plainText": "第二轮白板",
                "latex": r"\sqrt{12}=2\sqrt{3}",
                "strokeCount": 4,
            }
        ],
        allowed_step_ids=["board"],
        round_index=2,
        history=[],
        purpose="peer_assessment",
        round_board_snapshots=[
            {
                "roundIndex": 1,
                "boardPlainText": "第一轮写了分解",
                "boardLatex": r"\sqrt{12}=\sqrt{4\cdot 3}",
                "strokeCount": 6,
            }
        ],
    )
    assert "【各轮白板摘要】" in prompt
    assert "第 1 轮" in prompt
    assert "第一轮写了分解" in prompt
    assert "【本轮（第 2 轮）白板整板识别】" in prompt
    assert "第二轮白板" in prompt
