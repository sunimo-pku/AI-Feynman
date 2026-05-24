"""独立教师 Agent：李老师角色。

- 学生主动「需要提示」 → `generate_teacher_hint`
- 同伴评估全员听懂时 → `generate_teacher_summary`（含 approved 数学复核）

第十二轮第五轮（砍 OCR + 多模型多样性）：李老师切到 Kimi-K2.6 multimodal
（DashScope route），能**直接看到本轮整板照片 + 历史轮整板照片**做数学复核，
不再依赖 OCR LaTeX 文字。与同伴评估里大雄共用 Kimi，形成「Kimi 老师 + Kimi 大雄
+ Qwen 小明 / 班长」的多样性组合。DeepSeek 文本路径保留作 fallback。
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from app.config import Config
from app.services.kimi import (
    deepseek_api_key_configured,
    deepseek_client,
    deepseek_thinking_disabled_extra_body,
    kimi_dashscope_api_key_configured,
    kimi_dashscope_client,
)
from app.services.lecture_agent import (
    LectureAgentError,
    _build_user_prompt,
    _sanitize_history,
    _sanitize_round_board_snapshots,
    _strip_markdown_fence,
)
from app.services.peer_assessment_agent import (
    _VISION_MAX_IMAGE_B64_LEN,
    _VISION_MAX_IMAGES,
    _build_vision_user_content,
    _collect_board_images,
)
from app.services.question_bank import resolve_standard_answer

logger = logging.getLogger(__name__)

# 文本兜底用 DeepSeek-V4-Flash；multimodal 主路径用 Kimi-K2.6（via DashScope）。
_TEACHER_FALLBACK_MODEL = Config.DEEPSEEK_MODEL
_TEACHER_VISION_MODEL = Config.KIMI_K2_MODEL
_TEACHER_TEMPERATURE = 0.3
_LLM_TIMEOUT_SECONDS = 6.0
_VISION_TIMEOUT_SECONDS = 12.0
_MAX_TEXT_LEN = 220
_MAX_SUMMARY_TEXT_LEN = 140
_MAX_METHOD_SUMMARY_LEN = 180

_TEACHER_SYSTEM_PROMPT = """你是初中数学讲题课的李老师。
**只有当学生主动点击「需要提示」时**，你才发言；平时不参与同伴追问。

【你的任务】
1. 温和脚手架式引导，帮学生自己发现下一步该想什么；
2. **绝不**直接公布完整答案，也不替学生做完推导；
3. 可以指出「该检查哪个概念 / 条件 / 定义域」，最多给半句方向性暗示；
4. 优先引用学生已写步骤或口述中的**真实**内容（禁止编造）；
5. 语气友好、尊重；数学符号用 LaTeX；
6. 发言不超过 180 个中文字符；
7. `highlightStepIds` 只能引用白名单里的 stepId。

【反幻觉】
- 禁止编造学生没说过的话；
- 不要替学生脑补还没写下来的步骤；
- 题面里没出现的数值 / 公式，不要假装是学生给的。

只输出**一个 JSON 对象**，不要 Markdown 代码块：
{
  "text": "……（含 LaTeX，不超过 180 中文字符）",
  "highlightStepIds": ["step_x"]
}
"""


def _call_teacher_llm(
    *,
    system_prompt: str,
    user_prompt: str,
    board_images: list[dict[str, Any]],
    max_tokens: int,
    label: str,
) -> str:
    """统一李老师 LLM 调用：优先 Kimi-K2.6 multimodal，失败回 DeepSeek 文本。

    Kimi 在 DashScope 上能真正读 image_url（实测，scripts/test_kimi_vision.py），
    所以老师也能直接看图独立复核学生白板内容，不需要任何 OCR 文字。
    """
    use_vision = (
        bool(board_images)
        and kimi_dashscope_api_key_configured()
    )
    t0 = time.monotonic()
    raw = ""
    if use_vision:
        user_content = _build_vision_user_content(
            text_prompt=user_prompt,
            board_images=board_images,
        )
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ]
        try:
            resp = (
                kimi_dashscope_client.with_options(max_retries=0)
                .chat.completions.create(
                    model=_TEACHER_VISION_MODEL,
                    messages=messages,
                    temperature=_TEACHER_TEMPERATURE,
                    max_tokens=max_tokens,
                    response_format={"type": "json_object"},
                    timeout=_VISION_TIMEOUT_SECONDS,
                )
            )
            raw = (resp.choices[0].message.content or "") if resp.choices else ""
        except Exception as e:  # noqa: BLE001
            logger.exception(
                "[teacher-agent] %s kimi vision failed: %s (fallback to text)",
                label,
                e,
            )
            raw = ""
        if raw:
            logger.info(
                "[teacher-agent] %s kimi-vision ms=%.0f images=%d",
                label,
                (time.monotonic() - t0) * 1000,
                len(board_images),
            )
            return raw

    # text fallback
    if not deepseek_api_key_configured():
        raise LectureAgentError(
            "no LLM key configured for teacher (need KIMI_DASHSCOPE_KEY or DEEPSEEK_API_KEY)"
        )
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = (
            deepseek_client.with_options(max_retries=0)
            .chat.completions.create(
                model=_TEACHER_FALLBACK_MODEL,
                messages=messages,
                temperature=_TEACHER_TEMPERATURE,
                max_tokens=max_tokens,
                response_format={"type": "json_object"},
                timeout=_LLM_TIMEOUT_SECONDS,
                extra_body=deepseek_thinking_disabled_extra_body(),
            )
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[teacher-agent] %s deepseek fallback failed: %s", label, e)
        raise LectureAgentError(f"Teacher {label} LLM failed: {e}") from e
    logger.info(
        "[teacher-agent] %s deepseek-fallback ms=%.0f",
        label,
        (time.monotonic() - t0) * 1000,
    )
    return raw


def generate_teacher_hint(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
    round_board_snapshots: list[dict[str, Any]] | None = None,
    current_board_image_base64: str = "",
    section_profile_context: str = "",
) -> dict[str, Any]:
    """生成一条李老师提示 turn。

    `current_board_image_base64`：本轮整板 PNG，传给 Kimi-K2.6 看图复核。
    """

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]

    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))
    prior_boards = _sanitize_round_board_snapshots(
        round_board_snapshots,
        current_round=safe_round,
    )
    board_images = _collect_board_images(
        prior_boards,
        current_board_image_base64,
        current_round=safe_round,
    )

    context_prompt = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
        history=cleaned_history,
        purpose="teacher",
        round_board_snapshots=prior_boards,
        vision_attached=bool(board_images),
        section_profile_context=section_profile_context,
    )
    user_prompt = (
        "【学生请求】学生刚刚主动点击了「需要提示」。请给出一条脚手架式提示，"
        "不要直接给答案。\n\n"
        f"{context_prompt}\n\n"
        "请只输出一个 JSON 对象，符合上面的输出格式。"
    )
    raw = _call_teacher_llm(
        system_prompt=_TEACHER_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        board_images=board_images,
        max_tokens=600,
        label="hint",
    )

    try:
        payload = json.loads(_strip_markdown_fence(raw or ""))
        if not isinstance(payload, dict):
            raise ValueError("top-level not object")
    except (json.JSONDecodeError, ValueError) as e:
        raise LectureAgentError("Teacher hint response could not be parsed") from e

    text = str(payload.get("text") or "").strip()
    if not text:
        raise LectureAgentError("Teacher hint text is empty")
    if len(text) > _MAX_TEXT_LEN:
        text = text[:_MAX_TEXT_LEN].rstrip() + "…"

    allowed_set = set(allowed_step_ids)
    fallback_step = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback_step:
        highlight = [fallback_step]

    logger.info(
        "[teacher-agent] hint ok section=%s round=%d history=%d",
        section_id,
        safe_round,
        len(cleaned_history),
    )

    return {
        "turn_id": "hint_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": text,
        "highlight_step_ids": highlight,
        "source": "llm",
    }


_TEACHER_SUMMARY_PROMPT = """你是初中数学讲题课的李老师。
同伴评估显示三名同学都听懂了，但**你必须独立核对**学生讲解数学是否正确。

【首要任务 · 核对】
对照【标准解答要点】（若有）或题面自行推理：
- 若学生**明显讲错**（法则用错、漏条件、结果错、与标准要点矛盾）：
  `"approved": false`，`text` 温和指出**哪一类**问题（不要直接给完整正确答案），
  `methodSummary` 留空 `""`。
- 若数学上**站得住**：
  `"approved": true`，`text` 肯定学生本轮讲清楚的关键点；
  `methodSummary` 用 2～3 句话归纳此类题通用方法。

【表达】
- 语气温和；数学用 LaTeX；`text` ≤120 字，`methodSummary` ≤160 字；
- `highlightStepIds` 只能引用白名单 stepId。
- 禁止写「大雄验证了…」等仿佛同伴刚才发言；最多一句「同伴们都听懂了」。

只输出一个 JSON 对象：
{
  "approved": true | false,
  "text": "……",
  "methodSummary": "……",
  "highlightStepIds": ["step_x"]
}
"""


def _parse_bool_field(value: Any, *, field: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    raise LectureAgentError(f"Teacher summary {field} must be boolean")


def _peer_understood_ack(peer_assessments: list[dict[str, Any]] | None) -> str:
    """收束小结用：只传「谁听懂了」，不传 assessment reason（避免李老师转述未开口的同伴）。"""
    order = ("小明", "大雄", "班长")
    name_by_role = {
        "xiaoming": "小明",
        "daxiong": "大雄",
        "monitor": "班长",
        "classleader": "班长",
    }
    understood: set[str] = set()
    for item in peer_assessments or []:
        if not isinstance(item, dict) or not bool(item.get("understood")):
            continue
        display = str(item.get("display_name") or item.get("displayName") or "").strip()
        role = str(item.get("role") or "").strip().lower()
        if display:
            understood.add(display)
        elif role in name_by_role:
            understood.add(name_by_role[role])
    if not understood:
        return "三名同伴均表示听懂（本轮未当众发言）。"
    ordered = [n for n in order if n in understood]
    for n in sorted(understood):
        if n not in ordered:
            ordered.append(n)
    return "、".join(ordered) + "均表示听懂（本轮未当众发言）。"


def apply_teacher_completion_gate(
    result: dict[str, Any],
    teacher_summary: dict[str, Any] | None,
) -> dict[str, Any]:
    """李老师核对不通过时，禁止 completed。"""
    approved = False
    if teacher_summary is not None:
        try:
            approved = _parse_bool_field(
                teacher_summary.get("approved"),
                field="approved",
            )
        except LectureAgentError:
            approved = False
    if teacher_summary is None or approved:
        return result
    patched = dict(result)
    patched["status"] = "needs_explanation"
    patched["all_understood"] = False
    patched["mastery_delta"] = 0
    return patched


def generate_teacher_summary(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
    peer_assessments: list[dict[str, Any]] | None = None,
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
    current_board_image_base64: str = "",
    section_profile_context: str = "",
) -> dict[str, Any]:
    """三名同伴都听懂时，李老师收束小结。"""

    allowed_step_ids = [
        str(s.get("stepId") or s.get("step_id") or "").strip() for s in steps
    ]
    allowed_step_ids = [sid for sid in allowed_step_ids if sid]
    cleaned_history = _sanitize_history(history)
    safe_round = max(1, int(round_index or 1))
    prior_boards = _sanitize_round_board_snapshots(
        round_board_snapshots,
        current_round=safe_round,
    )
    board_images = _collect_board_images(
        prior_boards,
        current_board_image_base64,
        current_round=safe_round,
    )

    std = resolve_standard_answer(
        question_id=question_id,
        client_answer=standard_answer,
    )
    context_prompt = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
        history=cleaned_history,
        purpose="teacher_summary",
        standard_answer=std,
        round_board_snapshots=prior_boards,
        vision_attached=bool(board_images),
        section_profile_context=section_profile_context,
    )
    peer_ack = _peer_understood_ack(peer_assessments)

    user_prompt = (
        "【收束场景】同伴评估为全员听懂，但**你必须独立核对数学是否正确**。"
        "下列听懂确认不是同伴当众说过的话。\n"
        f"【同伴听懂确认】{peer_ack}\n\n"
        f"{context_prompt}\n\n"
        "请只输出一个 JSON 对象（含 approved 字段）。"
    )
    raw = _call_teacher_llm(
        system_prompt=_TEACHER_SUMMARY_PROMPT,
        user_prompt=user_prompt,
        board_images=board_images,
        max_tokens=700,
        label="summary",
    )

    try:
        payload = json.loads(_strip_markdown_fence(raw or ""))
        if not isinstance(payload, dict):
            raise ValueError("top-level not object")
    except (json.JSONDecodeError, ValueError) as e:
        raise LectureAgentError("Teacher summary response could not be parsed") from e

    text = str(payload.get("text") or "").strip()
    if not text:
        raise LectureAgentError("Teacher summary text is empty")
    if len(text) > _MAX_SUMMARY_TEXT_LEN:
        text = text[:_MAX_SUMMARY_TEXT_LEN].rstrip() + "…"

    method_summary = str(
        payload.get("methodSummary") or payload.get("method_summary") or ""
    ).strip()
    if len(method_summary) > _MAX_METHOD_SUMMARY_LEN:
        method_summary = method_summary[:_MAX_METHOD_SUMMARY_LEN].rstrip() + "…"

    approved = _parse_bool_field(payload.get("approved"), field="approved")
    if not approved:
        method_summary = ""

    allowed_set = set(allowed_step_ids)
    fallback_step = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback_step:
        highlight = [fallback_step]

    logger.info(
        "[teacher-agent] summary ok section=%s round=%d approved=%s",
        section_id,
        safe_round,
        approved,
    )

    return {
        "turn_id": "summary_1",
        "role": "teacher",
        "display_name": "李老师",
        "text": text,
        "method_summary": method_summary,
        "highlight_step_ids": highlight,
        "approved": approved,
        "source": "llm",
    }
