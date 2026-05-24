"""同伴听课评估：小明 / 大雄 / 班长各 1 次独立 LLM 调用。

P1：学生每提交一轮讲解，三人并行评估「听懂 / 没听懂」及理由。
全员听懂时由 `teacher_agent.generate_teacher_summary` 收束（在路由层触发）。

第十二轮第五轮（砍 OCR + 多模型多样性）：
- 同伴**全员走 multimodal**，直接看每轮整板照片对比新旧笔迹，OCR 文字
  彻底不再作为同伴的视觉证据来源；
- **按 role 分发模型**保持多样性：
  - `xiaoming`、`monitor` → Qwen-VL-Max-latest（验证型追问，更稳重）
  - `daxiong` → Kimi-K2.6 via DashScope（拓展型追问，更有变化）
- 每条评估额外返回 `boardSummary` 字段（≤30 字描述本轮新增内容），供
  `live_lecture_session` 写进 `history` 与回放，**完全取代** OCR 文字摘要；
- 仅当对应 multimodal key 缺失或调用失败时，最后兜底退到 DeepSeek 文本，
  不再"先走 DeepSeek 主路径"。
"""

from __future__ import annotations

import json
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from openai import OpenAI

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
    _DEFAULT_DISPLAY_NAME,
    _PEER_ROLES,
    _build_user_prompt,
    _sanitize_history,
    _sanitize_round_board_snapshots,
    _strip_markdown_fence,
)
from app.services.peer_harmonize import (
    find_misconception_speaker,
    harmonize_peer_assessments,
    normalize_question_kind,
    recompute_round_status,
)
from app.services.question_bank import resolve_standard_answer
from app.services.peer_personas import (
    PEER_ASSESSMENT_USER_SUFFIX,
    build_monitor_misconception_correction_system_prompt,
    build_peer_assessment_system_prompt,
    default_assessment_reason,
)

logger = logging.getLogger(__name__)

_ASSESSMENT_MODEL = Config.DEEPSEEK_MODEL  # 仅作 DeepSeek 兜底使用
_ASSESSMENT_TEMPERATURE = 0.45
_ASSESSMENT_EXTRA_BODY: dict[str, Any] = {}  # 见 deepseek_thinking_disabled_extra_body()
_LLM_TIMEOUT_SECONDS = 5.0
# 同伴 multimodal 路径单次需要读多张白板照片，比纯文本慢；放宽一点。
_VISION_TIMEOUT_SECONDS = 12.0
_MAX_REASON_LEN = 220
_MAX_BOARD_SUMMARY_LEN = 30
# multimodal 路径单次最多附几张白板图（含本轮整板）。
_VISION_MAX_IMAGES = 4
# 客户端送上来的 PNG 偶尔太大，过 6MB 直接跳过。
_VISION_MAX_IMAGE_B64_LEN = 6_000_000

# 按 role 分发 multimodal 模型，保持追问风格多样性：
#   - xiaoming / monitor：Qwen-VL-Max-latest（验证型，输出风格更稳重）
#   - daxiong：Kimi-K2.6（拓展型，输出风格更跳跃，专门做验算 / 变式追问）
# 实测两家延迟都在亚秒到 1.5s，差异不影响 demo 节奏。
_ROLE_VISION_MODELS: dict[str, str] = {
    "xiaoming": "qwen",
    "daxiong": "kimi",
    "monitor": "qwen",
}


def _qwen_vl_client() -> OpenAI | None:
    if not Config.ALIYUN_API_KEY:
        return None
    return OpenAI(
        api_key=Config.ALIYUN_API_KEY,
        base_url=Config.ALIYUN_BASE_URL,
    )


def _vision_client_for_role(role: str) -> tuple[OpenAI | None, str, str]:
    """根据 role 返回 (client, model_id, provider_tag)。

    provider_tag 仅用于日志：``'qwen'`` / ``'kimi'``，方便观测多样性是否真的
    被分配。client / model_id 为 None / '' 时上层走 DeepSeek 文本兜底。
    """
    provider = _ROLE_VISION_MODELS.get(role, "qwen")
    if provider == "kimi" and kimi_dashscope_api_key_configured():
        return kimi_dashscope_client, Config.KIMI_K2_MODEL, "kimi"
    # Kimi 未配置时也回落到 Qwen-VL，保证多模态主路径仍然有效
    qwen = _qwen_vl_client()
    if qwen is not None:
        return qwen, Config.QWEN_VL_MODEL, "qwen"
    return None, "", ""
# 与 lecture_agent._HISTORY_KEEP_LAST 对齐（约 10 轮完整闭环）。
# 不再在 peer 路径做更紧的二次裁切——同伴能看到的跨轮记忆与全局一致，
# 包括前几轮学生 ASR 全文、三人判断与老师收束。如果未来 prompt 长度
# 真的成为瓶颈，再考虑按 roundIndex（而不是按条数）裁切。
_PEER_HISTORY_KEEP = 60

# 「你说『…』」类表述：引号内必须出现在本轮 student_speech_text 里。
_SPEECH_QUOTE_RE = re.compile(
    r"(?:你说|你刚才说|你刚刚说)[「『\"']([^」』\"']{2,})[」』\"']"
)


def _parse_bool_field(value: Any, *, field: str, role: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    raise LectureAgentError(f"{role} assessment {field} must be boolean")


def _system_prompt_for_role(role: str) -> str:
    return build_peer_assessment_system_prompt(role)


def _step_evidence_corpus(steps: list[dict[str, Any]]) -> str:
    bits: list[str] = []
    for s in steps:
        plain = str(s.get("plainText") or s.get("plain_text") or "").strip()
        latex = str(s.get("latex") or "").strip()
        if plain:
            bits.append(plain)
        if latex:
            bits.append(latex)
    return " ".join(bits)


def _sanitize_reason_quotes(
    reason: str,
    *,
    student_speech_text: str,
    steps: list[dict[str, Any]],
) -> str:
    """把误标成「你说」但不在口述里的引用，改成「你写的」或去掉。"""
    speech = (student_speech_text or "").strip()
    step_corpus = _step_evidence_corpus(steps)
    out = reason
    for match in list(_SPEECH_QUOTE_RE.finditer(reason)):
        quoted = match.group(1).strip()
        if not quoted:
            continue
        if quoted in speech:
            continue
        replacement = (
            f"你写的「{quoted}」"
            if quoted in step_corpus
            else "这里"
        )
        out = out.replace(match.group(0), replacement, 1)
    return out


def _parse_assessment(
    raw: str,
    *,
    role: str,
    allowed_step_ids: list[str],
    student_speech_text: str,
    steps: list[dict[str, Any]],
) -> dict[str, Any]:
    cleaned = _strip_markdown_fence(raw or "")
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise LectureAgentError(f"{role} assessment JSON invalid: {e}") from e
    if not isinstance(payload, dict):
        raise LectureAgentError(f"{role} assessment top-level not object")

    understood = _parse_bool_field(
        payload.get("understood"),
        field="understood",
        role=role,
    )
    reason = str(payload.get("reason") or "").strip()
    if not reason:
        reason = default_assessment_reason(role=role, understood=understood)
    reason = _sanitize_reason_quotes(
        reason,
        student_speech_text=student_speech_text,
        steps=steps,
    )
    if len(reason) > _MAX_REASON_LEN:
        reason = reason[:_MAX_REASON_LEN].rstrip() + "…"

    allowed_set = set(allowed_step_ids)
    fallback = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback:
        highlight = [fallback]

    question_kind = normalize_question_kind(
        role=role,
        understood=understood,
        raw_kind=payload.get("questionKind") or payload.get("question_kind"),
    )

    board_summary = str(
        payload.get("boardSummary") or payload.get("board_summary") or ""
    ).strip()
    if len(board_summary) > _MAX_BOARD_SUMMARY_LEN:
        board_summary = board_summary[:_MAX_BOARD_SUMMARY_LEN].rstrip() + "…"

    return {
        "role": role,
        "display_name": _DEFAULT_DISPLAY_NAME[role],
        "understood": understood,
        "reason": reason,
        "highlight_step_ids": highlight,
        "question_kind": question_kind,
        "board_summary": board_summary,
    }


def assess_one_peer(
    *,
    role: str,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
    history: list[dict[str, Any]],
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
    current_board_image_base64: str = "",
    section_profile_context: str = "",
) -> dict[str, Any]:
    """单次 LLM 评估一名同伴（供 live session 并行 + 增量推送）。

    `current_board_image_base64`：本轮（学生**正在评估的这一轮**）的整板 PNG。
    `round_board_snapshots[i].board_image_base64`：前几轮归档的整板 PNG。
    两者都有时走 Qwen-VL multimodal，让同伴**用图片**而不是 OCR LaTeX
    判断「本轮真正新增的笔迹」。
    """
    return _assess_one_peer(
        role=role,
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=history,
        standard_answer=standard_answer,
        round_board_snapshots=round_board_snapshots,
        current_board_image_base64=current_board_image_base64,
        section_profile_context=section_profile_context,
    )


def _valid_image_b64(value: str | None) -> bool:
    if not value:
        return False
    if len(value) > _VISION_MAX_IMAGE_B64_LEN:
        return False
    return True


def _collect_board_images(
    prior_boards: list[dict[str, Any]],
    current_board_image_base64: str,
    *,
    current_round: int,
) -> list[dict[str, Any]]:
    """收集本次同伴评估要带的所有整板照片，按轮次从早到晚排序。

    每条返回结构：``{"round": int, "image_base64": str, "is_current": bool}``。
    超出 `_VISION_MAX_IMAGES` 时丢掉**最早**的几轮，留下最近几轮 + 本轮整板。
    """
    out: list[dict[str, Any]] = []
    for item in prior_boards:
        b64 = str(item.get("board_image_base64") or "").strip()
        if not _valid_image_b64(b64):
            continue
        round_idx = int(item.get("round_index") or 0)
        if round_idx <= 0 or round_idx >= current_round:
            continue
        out.append({
            "round": round_idx,
            "image_base64": b64,
            "is_current": False,
        })
    if _valid_image_b64(current_board_image_base64):
        out.append({
            "round": max(1, current_round),
            "image_base64": current_board_image_base64.strip(),
            "is_current": True,
        })
    out.sort(key=lambda x: (x["round"], 1 if x["is_current"] else 0))
    if len(out) > _VISION_MAX_IMAGES:
        # 永远保留最后一张（本轮），其余只保留最近 N-1 轮
        head = out[:-1][-(_VISION_MAX_IMAGES - 1):]
        out = head + [out[-1]]
    return out


def _build_vision_user_content(
    *,
    text_prompt: str,
    board_images: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """把 text + 多张白板照片拼成 OpenAI multimodal user content。

    每张图片前会先放一个 text 段，标明轮次和是否「本轮整板」，让 VL 模型
    在 vision context 里也能明确分辨「上一轮 vs 本轮」。
    """
    content: list[dict[str, Any]] = []
    for item in board_images:
        round_idx = item["round"]
        is_current = item["is_current"]
        label = (
            f"【第 {round_idx} 轮 · 本轮整板照片（可能仍包含上一轮未擦笔迹）】"
            if is_current
            else f"【第 {round_idx} 轮 · 历史整板照片（已归档）】"
        )
        content.append({"type": "text", "text": label})
        content.append(
            {
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/png;base64,{item['image_base64']}",
                },
            }
        )
    content.append({"type": "text", "text": text_prompt})
    return content


def _assess_one_peer(
    *,
    role: str,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
    history: list[dict[str, Any]],
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
    current_board_image_base64: str = "",
    section_profile_context: str = "",
) -> dict[str, Any]:
    cleaned_history = _sanitize_history(history)
    if len(cleaned_history) > _PEER_HISTORY_KEEP:
        cleaned_history = cleaned_history[-_PEER_HISTORY_KEEP:]
    std = (standard_answer or "").strip() or resolve_standard_answer(
        question_id=question_id,
    )
    prior_boards = _sanitize_round_board_snapshots(
        round_board_snapshots,
        current_round=round_index,
    )

    board_images = _collect_board_images(
        prior_boards,
        current_board_image_base64,
        current_round=round_index,
    )
    vision_client, vision_model, provider = _vision_client_for_role(role)
    use_vision = vision_client is not None and bool(board_images)

    context = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=cleaned_history,
        purpose="peer_assessment",
        standard_answer=std,
        round_board_snapshots=prior_boards,
        assessing_role=role,
        vision_attached=use_vision,
        section_profile_context=section_profile_context,
    )
    # 多模态路径要求模型额外输出 `boardSummary` —— 用作下一轮 history 与
    # 家长端落库的文字摘要，替代砍掉的 OCR 文本。
    board_summary_hint = (
        '\n额外请求：输出 JSON 时**必须**包含 `boardSummary` 字段，'
        "≤30 个中文字符，用 1 句口语描述「本轮学生新写或新说的关键内容」；"
        "若本轮没有新增内容（学生只口述、白板无变化）写 \"本轮无新增笔迹\"。"
    )
    user_prompt = (
        f"【你的身份】{ _DEFAULT_DISPLAY_NAME[role] }（role={role}）\n"
        f"{PEER_ASSESSMENT_USER_SUFFIX}\n\n"
        f"{context}\n\n"
        f"请只输出一个 JSON 对象。{board_summary_hint if use_vision else ''}"
    )

    t0 = time.monotonic()
    if use_vision:
        assert vision_client is not None  # for mypy
        user_content = _build_vision_user_content(
            text_prompt=user_prompt,
            board_images=board_images,
        )
        messages = [
            {"role": "system", "content": _system_prompt_for_role(role)},
            {"role": "user", "content": user_content},
        ]
        try:
            resp = vision_client.with_options(max_retries=0).chat.completions.create(
                model=vision_model,
                messages=messages,
                temperature=_ASSESSMENT_TEMPERATURE,
                max_tokens=400,
                response_format={"type": "json_object"},
                timeout=_VISION_TIMEOUT_SECONDS,
            )
            raw = (resp.choices[0].message.content or "") if resp.choices else ""
        except Exception as e:  # noqa: BLE001
            logger.exception(
                "[peer-assessment] %s %s failed: %s (will fallback to text)",
                role,
                provider,
                e,
            )
            raw = ""
        if raw:
            parsed = _parse_assessment(
                raw,
                role=role,
                allowed_step_ids=allowed_step_ids,
                student_speech_text=student_speech_text,
                steps=steps,
            )
            logger.info(
                "[peer-assessment] %s %s ms=%.0f images=%d understood=%s kind=%s summary=%r",
                role,
                provider,
                (time.monotonic() - t0) * 1000,
                len(board_images),
                parsed.get("understood"),
                parsed.get("question_kind"),
                parsed.get("board_summary"),
            )
            return parsed
        # multimodal 失败 → 重新生成不带 vision_attached 提示的纯文本 context
        context = _build_user_prompt(
            section_id=section_id,
            question_id=question_id,
            question_prompt=question_prompt,
            student_speech_text=student_speech_text,
            steps=steps,
            allowed_step_ids=allowed_step_ids,
            round_index=round_index,
            history=cleaned_history,
            purpose="peer_assessment",
            standard_answer=std,
            round_board_snapshots=prior_boards,
            assessing_role=role,
            vision_attached=False,
            section_profile_context=section_profile_context,
        )
        user_prompt = (
            f"【你的身份】{ _DEFAULT_DISPLAY_NAME[role] }（role={role}）\n"
            f"{PEER_ASSESSMENT_USER_SUFFIX}\n\n"
            f"{context}\n\n"
            "请只输出一个 JSON 对象。"
        )

    messages = [
        {"role": "system", "content": _system_prompt_for_role(role)},
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_ASSESSMENT_MODEL,
            messages=messages,
            temperature=_ASSESSMENT_TEMPERATURE,
            max_tokens=280,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=deepseek_thinking_disabled_extra_body(),
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.exception("[peer-assessment] %s text fallback failed: %s", role, e)
        raise LectureAgentError(f"{role} assessment LLM failed: {e}") from e

    parsed = _parse_assessment(
        raw,
        role=role,
        allowed_step_ids=allowed_step_ids,
        student_speech_text=student_speech_text,
        steps=steps,
    )
    logger.info(
        "[peer-assessment] %s text-fallback ms=%.0f understood=%s kind=%s",
        role,
        (time.monotonic() - t0) * 1000,
        parsed.get("understood"),
        parsed.get("question_kind"),
    )
    return parsed


def _generate_monitor_misconception_correction(
    *,
    xiaoming_item: dict[str, Any],
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
) -> dict[str, Any] | None:
    """小明误解型提问后，班长接一句帮腔纠偏（可选 LLM）。"""
    if not deepseek_api_key_configured():
        return None

    context = _build_user_prompt(
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=round_index,
        history=[],
        purpose="peer_assessment",
    )
    user_prompt = (
        f"【小明刚才的误解型提问】\n{xiaoming_item.get('reason', '')}\n\n"
        f"{context}\n\n"
        "请输出班长纠偏 JSON。"
    )
    messages = [
        {
            "role": "system",
            "content": build_monitor_misconception_correction_system_prompt(),
        },
        {"role": "user", "content": user_prompt},
    ]
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=_ASSESSMENT_MODEL,
            messages=messages,
            temperature=0.35,
            max_tokens=200,
            response_format={"type": "json_object"},
            timeout=_LLM_TIMEOUT_SECONDS,
            extra_body=deepseek_thinking_disabled_extra_body(),
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
    except Exception as e:  # noqa: BLE001
        logger.warning("[peer-assessment] monitor correction LLM failed: %s", e)
        return None

    cleaned = _strip_markdown_fence(raw or "")
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    text = str(payload.get("text") or "").strip()
    if not text:
        return None
    if len(text) > _MAX_REASON_LEN:
        text = text[:_MAX_REASON_LEN].rstrip() + "…"

    allowed_set = set(allowed_step_ids)
    fallback = allowed_step_ids[0] if allowed_step_ids else None
    highlight_raw = payload.get("highlightStepIds") or payload.get("highlight_step_ids") or []
    if not isinstance(highlight_raw, list):
        highlight_raw = []
    highlight: list[str] = []
    for sid in highlight_raw:
        sid_str = str(sid).strip()
        if sid_str and sid_str in allowed_set and sid_str not in highlight:
            highlight.append(sid_str)
    if not highlight and fallback:
        highlight = [fallback]

    return {
        "turn_id": "reply_monitor_misconception",
        "role": "monitor",
        "display_name": _DEFAULT_DISPLAY_NAME["monitor"],
        "text": text,
        "highlight_step_ids": highlight,
    }


def finalize_peer_assessment_round(
    *,
    assessments: list[dict[str, Any]],
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    allowed_step_ids: list[str],
    round_index: int,
) -> dict[str, Any]:
    harmonized = harmonize_peer_assessments(assessments)
    status_bits = recompute_round_status(harmonized)

    peer_replies: list[dict[str, Any]] = []
    misc = find_misconception_speaker(harmonized)
    if misc is not None:
        correction = _generate_monitor_misconception_correction(
            xiaoming_item=misc,
            section_id=section_id,
            question_id=question_id,
            question_prompt=question_prompt,
            student_speech_text=student_speech_text,
            steps=steps,
            allowed_step_ids=allowed_step_ids,
            round_index=round_index,
        )
        if correction is not None:
            peer_replies.append(correction)

    logger.info(
        "[peer-assessment] finalize round=%d speakers=%d replies=%d status=%s",
        round_index,
        sum(1 for a in harmonized if not a.get("understood")),
        len(peer_replies),
        status_bits["status"],
    )

    return {
        **status_bits,
        "assessments": harmonized,
        "peer_replies": peer_replies,
        "source": "llm",
    }


def generate_peer_assessments(
    *,
    section_id: str,
    question_id: str,
    question_prompt: str,
    student_speech_text: str,
    steps: list[dict[str, Any]],
    round_index: int = 1,
    history: list[dict[str, Any]] | None = None,
    standard_answer: str = "",
    round_board_snapshots: list[dict[str, Any]] | None = None,
    current_board_image_base64: str = "",
    section_profile_context: str = "",
) -> dict[str, Any]:
    """并行评估三名同伴，返回 assessments + all_understood。"""

    # multimodal 主路径需要 Qwen-VL（ALIYUN_API_KEY）或 Kimi-DashScope key 至少
    # 有一个；DeepSeek 仅作 fallback。三家全无才彻底跑不动。
    if (
        not Config.ALIYUN_API_KEY
        and not kimi_dashscope_api_key_configured()
        and not deepseek_api_key_configured()
    ):
        raise LectureAgentError(
            "no LLM key configured (need ALIYUN_API_KEY or KIMI_DASHSCOPE_KEY or DEEPSEEK_API_KEY)"
        )

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
    std = resolve_standard_answer(
        question_id=question_id,
        client_answer=standard_answer,
    )

    common_kwargs = {
        "section_id": section_id,
        "question_id": question_id,
        "question_prompt": question_prompt,
        "student_speech_text": student_speech_text,
        "steps": steps,
        "allowed_step_ids": allowed_step_ids,
        "round_index": safe_round,
        "history": cleaned_history,
        "standard_answer": std,
        "round_board_snapshots": prior_boards,
        "current_board_image_base64": current_board_image_base64,
        "section_profile_context": section_profile_context,
    }

    by_role: dict[str, dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {
            pool.submit(assess_one_peer, role=role, **common_kwargs): role
            for role in _PEER_ROLES
        }
        for fut in as_completed(futures):
            role = futures[fut]
            by_role[role] = fut.result()

    assessments = [by_role[r] for r in _PEER_ROLES if r in by_role]
    if len(assessments) != len(_PEER_ROLES):
        raise LectureAgentError("peer assessments incomplete")

    finalized = finalize_peer_assessment_round(
        assessments=assessments,
        section_id=section_id,
        question_id=question_id,
        question_prompt=question_prompt,
        student_speech_text=student_speech_text,
        steps=steps,
        allowed_step_ids=allowed_step_ids,
        round_index=safe_round,
    )

    logger.info(
        "[peer-assessment] section=%s round=%d understood=%d/3 status=%s",
        section_id,
        safe_round,
        sum(1 for a in finalized["assessments"] if a["understood"]),
        finalized["status"],
    )

    return finalized
