"""teacher_agent 收束小结：同伴未开口时不应喂 assessment reason 给 LLM。"""

from app.services.teacher_agent import _peer_understood_ack


def test_peer_understood_ack_omits_reason_text() -> None:
    assessments = [
        {
            "role": "daxiong",
            "display_name": "大雄",
            "understood": True,
            "reason": "我代了个数对上了，这步说得通。",
        },
        {
            "role": "monitor",
            "display_name": "班长",
            "understood": True,
            "reason": "嗯，整体思路我 get 了，特别是合并同类项那步。",
        },
        {
            "role": "xiaoming",
            "display_name": "小明",
            "understood": True,
            "reason": "哦，这步我好像跟上了。",
        },
    ]
    ack = _peer_understood_ack(assessments)
    assert "代入" not in ack
    assert "合并同类项" not in ack
    assert "小明" in ack and "大雄" in ack and "班长" in ack
    assert "未当众发言" in ack
