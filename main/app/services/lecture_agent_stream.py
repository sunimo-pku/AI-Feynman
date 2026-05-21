"""Token/行级流式多 Agent 追问。

主路径要求 Kimi 输出 NDJSON：turn_start/delta/turn_done/round_meta。解析失败时
直接抛错，由 session 层向前端发送 error 事件。
"""

from __future__ import annotations

import json
import logging
from typing import Any, Iterator

from app.config import Config
from app.services import lecture_agent
from app.services.kimi import kimi_client

logger = logging.getLogger(__name__)

_STREAM_SYSTEM_SUFFIX = """
请以 NDJSON 形式逐行输出事件；每行只能是一个 JSON 对象，不要 Markdown。
每行一个对象：
{"type":"turn_start","turnId":"turn_1","role":"xiaoming","displayName":"小明","highlightStepIds":["step_1"]}
{"type":"delta","turnId":"turn_1","delta":"..."}
{"type":"turn_done","turnId":"turn_1"}
{"type":"round_meta","status":"needs_explanation","masteryDelta":0}
"""


def generate_turn_events(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
) -> Iterator[dict[str, Any]]:
    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip()
        for s in steps
        if str(s.get("stepId") or s.get("step_id") or "").strip()
    ]
    if not Config.KIMI_API_KEY or Config.KIMI_API_KEY == "your_kimi_api_key_here":
        raise lecture_agent.LectureAgentError("KIMI_API_KEY is not configured")

    cleaned_history = lecture_agent._sanitize_history(history)  # noqa: SLF001
    user_prompt = lecture_agent._build_user_prompt(  # noqa: SLF001
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=max(1, int(round_index or 1)),
        history=cleaned_history,
    )
    messages = [
        {"role": "system", "content": lecture_agent._SYSTEM_PROMPT + _STREAM_SYSTEM_SUFFIX},  # noqa: SLF001
        {"role": "user", "content": user_prompt},
    ]
    try:
        stream = kimi_client.with_options(max_retries=0).chat.completions.create(
            model="kimi-k2.6",
            messages=messages,
            temperature=0.6,
            max_tokens=1200,
            stream=True,
            timeout=28.0,
            extra_body={"thinking": {"type": "disabled"}},
        )
        buf = ""
        saw_event = False
        for chunk in stream:
            delta = ""
            if chunk.choices:
                delta = chunk.choices[0].delta.content or ""
            if not delta:
                continue
            buf += delta
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                event = _parse_line(line, allowed_step_ids)
                if event:
                    saw_event = True
                    yield event
        if buf.strip():
            event = _parse_line(buf, allowed_step_ids)
            if event:
                saw_event = True
                yield event
        if not saw_event:
            raise ValueError("stream produced no valid NDJSON events")
        logger.info("[lecture-agent-stream] source=llm_stream section=%s", section_id)
    except Exception as e:  # noqa: BLE001
        logger.exception("[lecture-agent-stream] stream failed err=%s", e)
        raise lecture_agent.LectureAgentError(f"LLM stream failed: {e}") from e


def _parse_line(line: str, allowed_step_ids: list[str]) -> dict[str, Any] | None:
    line = line.strip()
    if not line:
        return None
    obj = json.loads(line)
    if not isinstance(obj, dict):
        return None
    typ = str(obj.get("type") or "")
    if typ == "turn_start":
        highlight = [s for s in obj.get("highlightStepIds", []) if s in allowed_step_ids]
        if not highlight and allowed_step_ids:
            highlight = [allowed_step_ids[0]]
        return {
            "type": "turn_start",
            "turnId": str(obj.get("turnId") or "turn_1"),
            "role": str(obj.get("role") or "teacher"),
            "displayName": str(obj.get("displayName") or "李老师"),
            "highlightStepIds": highlight,
        }
    if typ == "delta":
        return {
            "type": "delta",
            "turnId": str(obj.get("turnId") or "turn_1"),
            "delta": str(obj.get("delta") or ""),
        }
    if typ == "turn_done":
        return {"type": "turn_done", "turnId": str(obj.get("turnId") or "turn_1")}
    if typ == "round_meta":
        return {
            "type": "round_meta",
            "status": str(obj.get("status") or "needs_explanation"),
            "masteryDelta": int(obj.get("masteryDelta") or 0),
        }
    return None


