"""question_bank：标准解答要点解析与占位过滤。"""

from app.services.question_bank import (
    is_usable_standard_answer,
    resolve_standard_answer,
    standard_answer_for_question,
)


def test_is_usable_standard_answer_rejects_placeholder() -> None:
    assert not is_usable_standard_answer("")
    assert not is_usable_standard_answer("（教研占位）本题标准答案与完整步骤将于后续版本填入。")


def test_is_usable_standard_answer_accepts_real_hint() -> None:
    text = "（教研占位）标准解答要点：\n• $x \\ge 3$"
    assert is_usable_standard_answer(text)


def test_standard_answer_for_question_16_1() -> None:
    answer = standard_answer_for_question("q-s16-1-001")
    assert "ge 3" in answer or "x \\ge 3" in answer


def test_resolve_standard_answer_prefers_client() -> None:
    client = "（教研占位）标准解答要点：\n• client"
    bank = resolve_standard_answer(
        question_id="q-s16-1-001",
        client_answer=client,
    )
    assert bank == client


def test_resolve_standard_answer_falls_back_to_bank() -> None:
    bank = resolve_standard_answer(
        question_id="q-s16-1-001",
        client_answer="将于后续版本填入",
    )
    assert is_usable_standard_answer(bank)
