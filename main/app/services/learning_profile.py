"""可解释学习画像聚合服务。

画像分两层：
1. 规则层：从掌握度、讲题回顾、未完成会话中实时聚合可信骨架；
2. AI 提炼层：在规则证据范围内生成更像真实老师的长期观察。

AI 层失败或 key 未配置时静默降级到规则画像，避免展示链路被外部模型影响。
"""

from __future__ import annotations

import json
import logging
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    LearningProgress,
    LectureReview,
    LectureSessionRecord,
    StudentProfile,
    load_json,
)
from app.config import Config
from app.services.kimi import (
    deepseek_api_key_configured,
    deepseek_client,
    deepseek_thinking_disabled_extra_body,
)

logger = logging.getLogger(__name__)

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CURRICULUM_FILE = _PROJECT_ROOT / "data" / "curriculum" / "pep-junior-math.json"

_SECTION_WEAK_REASON: dict[str, str] = {
    "pep-g8-down-s16-1": "取值范围条件容易写漏",
    "pep-g8-down-s16-2": "公式法则前提条件不稳定",
    "pep-g8-down-s16-3": "合并运算时系数符号易错",
}

_CHAPTER_WEAK_REASON: dict[str, str] = {
    "有理数": "符号规则与绝对值几何意义容易混淆",
    "整式的加减": "去括号法则与合并同类项时系数符号易错",
    "一元一次方程": "去分母/移项时符号变化和漏乘项",
    "几何图形初步": "几何语言转换与图形性质对应关系不稳定",
    "相交线与平行线": "平行线判定定理与性质定理的题设结论容易颠倒",
    "实数": "平方根与算术平方根的概念边界不清晰",
    "平面直角坐标系": "坐标符号与象限特征、平移规律易混",
    "二元一次方程组": "消元时系数配平和代入回代容易算错",
    "不等式与不等式组": "不等号方向与边界值取舍容易混淆",
    "数据的收集、整理与描述": "统计图读取与总体样本概念对应不稳定",
    "三角形": "三角形内角和与外角定理的应用条件容易遗漏",
    "全等三角形": "全等判定条件选择不当或对应边顶点写错",
    "轴对称": "对称性质与最短路径模型的转化思路不稳定",
    "整式的乘法与因式分解": "公式套用和因式分解彻底性容易出问题",
    "分式": "分式有意义条件与运算中约分通分易错",
    "二次根式": "公式法则前提条件不稳定",
    "勾股定理": "直角三角形判定与勾股数适用条件容易遗漏",
    "平行四边形": "判定定理选择不当或辅助线添加思路不清晰",
    "一次函数": "k、b 符号与图像位置、增减性对应关系不稳定",
    "数据的分析": "方差/标准差的意义理解与计算步骤易错",
    "一元二次方程": "判别式应用与韦达定理前提条件容易忽略",
    "二次函数": "开口方向、对称轴与最值综合讨论不全面",
    "旋转": "旋转中心与旋转角度的对应关系容易搞混",
    "圆": "切线判定与圆周角定理的应用条件不稳定",
    "概率初步": "等可能事件判断与树状图列举容易遗漏",
    "相似": "相似判定条件选择与对应边比例书写易错",
    "锐角三角函数": "三角函数值记忆与直角三角形边角关系转化不稳定",
    "投影与视图": "三视图还原与投影类型判断容易混淆",
    "代数综合": "多个代数知识模块综合时思路切换不顺畅",
    "几何综合": "辅助线思路与多定理联用条件容易遗漏",
    "函数与应用": "实际问题中自变量取值范围与图像解释不稳定",
    "统计与概率": "复杂情境下统计量选择与概率模型建立易错",
    "全真模拟": "时间分配与综合题审题步骤容易出问题",
}


class ProfileEvidenceOut(BaseModel):
    label: str
    detail: str


class ProfileInsightOut(BaseModel):
    title: str
    description: str
    evidence: list[ProfileEvidenceOut] = Field(default_factory=list)
    section_id: str = Field("", serialization_alias="sectionId")

    model_config = {"populate_by_name": True}


class LearningProfileOut(BaseModel):
    student_name: str = Field("", serialization_alias="studentName")
    grade: str = ""
    overview: str = ""
    ai_summary: str = Field("", serialization_alias="aiSummary")
    profile_source: str = Field("rules", serialization_alias="profileSource")
    data_points: int = Field(0, serialization_alias="dataPoints")
    weak_knowledge: list[ProfileInsightOut] = Field(
        default_factory=list, serialization_alias="weakKnowledge"
    )
    strengths: list[ProfileInsightOut] = Field(default_factory=list)
    learning_traits: list[ProfileInsightOut] = Field(
        default_factory=list, serialization_alias="learningTraits"
    )
    next_actions: list[str] = Field(default_factory=list, serialization_alias="nextActions")
    primary_next_action: str = Field("", serialization_alias="primaryNextAction")
    recommended_section_id: str = Field("", serialization_alias="recommendedSectionId")
    generated_at: datetime = Field(
        default_factory=datetime.utcnow, serialization_alias="generatedAt"
    )

    model_config = {"populate_by_name": True}


def primary_next_action(profile: LearningProfileOut) -> str:
    """画像统一「下一步建议」出口：优先 nextActions，其次 overview。"""
    for action in profile.next_actions:
        cleaned = _trim(action, 120)
        if cleaned:
            return cleaned
    if profile.overview.strip():
        return _trim(profile.overview, 120)
    return "先完成 2-3 轮基础讲题，系统会开始形成稳定画像。"


def poster_teacher_tip(profile: LearningProfileOut) -> str:
    """总结海报教师建议：与 dashboard / 今日 Tab 共用 primaryNextAction。"""
    if profile.primary_next_action.strip():
        return profile.primary_next_action.strip()
    return primary_next_action(profile)


def profile_reason_for_section(profile: LearningProfileOut, section_id: str) -> str | None:
    """把画像薄弱点证据格式化为作业推荐 / 布置理由。"""
    sid = (section_id or "").strip()
    if not sid:
        return None
    for item in profile.weak_knowledge:
        if item.section_id != sid:
            continue
        parts: list[str] = [item.title]
        mastery_bit = ""
        caution_bit = ""
        for ev in item.evidence:
            if ev.label == "掌握度":
                mastery_bit = ev.detail
            elif ev.label == "错因记录":
                caution_bit = f"错因：{ev.detail}"
        if mastery_bit:
            parts.append(mastery_bit)
        if caution_bit:
            parts.append(caution_bit)
        elif item.description:
            parts.append(item.description)
        return " · ".join(parts)
    return None


def profile_reason_for_mistake(
    profile: LearningProfileOut,
    *,
    section_id: str,
    caution: str,
) -> str:
    """易错回顾推荐理由：优先对齐画像错因证据，再回落到回顾原文。"""
    sid = (section_id or "").strip()
    caution_clean = _trim(caution, 48)
    for item in profile.weak_knowledge:
        if item.section_id == sid:
            section_reason = profile_reason_for_section(profile, sid)
            if section_reason:
                return f"画像薄弱点 · {section_reason}"
    for trait in profile.learning_traits:
        if trait.title == "主要错因模式" and caution_clean in trait.description:
            return f"画像错因模式 · {caution_clean}"
    return f"易错回顾：{caution_clean}"


_AI_PROFILE_SYSTEM_PROMPT = """你是初中数学学习产品里的长期画像老师。

你会收到一份【规则画像】和一组【证据材料】。请在证据范围内提炼学生长期学习模式。

硬性要求：
1. 只能基于输入证据，不得编造学生行为、题目或分数。
2. 保留规则画像里的薄弱点和优势判断，不要推翻硬证据。
3. 语气像真实数学老师：具体、温和、可行动，不要营销话术。
4. 只输出 JSON 对象，不要 Markdown。

JSON 格式：
{
  "overview": "不超过80字的总览",
  "aiSummary": "不超过120字的老师观察",
  "learningTraits": [
    {
      "title": "不超过12字",
      "description": "不超过80字",
      "evidence": [{"label": "证据类型", "detail": "证据详情"}]
    }
  ],
  "nextActions": ["不超过48字的建议"]
}

learningTraits 最多 3 条，nextActions 最多 3 条。每条 trait 至少带 1 条证据。
"""

_AI_PROFILE_TIMEOUT_SECONDS = 5.0
_AI_PROFILE_MAX_TOKENS = 900


def _load_section_labels() -> tuple[dict[str, str], dict[str, str]]:
    try:
        payload = json.loads(_CURRICULUM_FILE.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover - startup diagnostic only
        logger.warning("Failed to load curriculum labels for profile: %s", exc)
        return {}, {}

    labels: dict[str, str] = {}
    section_chapter: dict[str, str] = {}
    for book in payload.get("books", []):
        for chapter in book.get("chapters", []):
            chapter_title = str(chapter.get("title") or "").strip()
            for section in chapter.get("sections", []):
                section_id = str(section.get("id") or "")
                label = str(section.get("label") or section.get("title") or "")
                if section_id and label:
                    labels[section_id] = label
                if section_id and chapter_title:
                    section_chapter[section_id] = chapter_title
    return labels, section_chapter


_SECTION_LABEL, _SECTION_CHAPTER = _load_section_labels()


def _label_for(section_id: str) -> str:
    return _SECTION_LABEL.get(section_id, section_id)


def _reason_for(section_id: str) -> str:
    if section_id in _SECTION_WEAK_REASON:
        return _SECTION_WEAK_REASON[section_id]
    chapter = _SECTION_CHAPTER.get(section_id, "")
    if chapter in _CHAPTER_WEAK_REASON:
        return _CHAPTER_WEAK_REASON[chapter]
    return "近期练习覆盖不足，需要更多讲题证据"


def _trim(text: str, limit: int = 54) -> str:
    clean = " ".join((text or "").strip().split())
    if len(clean) <= limit:
        return clean
    return f"{clean[:limit]}…"


def _evidence(label: str, detail: str) -> ProfileEvidenceOut:
    return ProfileEvidenceOut(label=label, detail=detail)


def _compact_global_insight(item: ProfileInsightOut) -> ProfileInsightOut:
    """全册展示画像：每条只保留 1 条证据，控制卡片体积。"""
    return item.model_copy(update={"evidence": item.evidence[:1]})


def _insight_to_dict(item: ProfileInsightOut) -> dict[str, Any]:
    return {
        "title": item.title,
        "description": item.description,
        "evidence": [
            {"label": ev.label, "detail": ev.detail}
            for ev in item.evidence
        ],
    }


def _profile_to_ai_input(
    *,
    rule_profile: LearningProfileOut,
    reviews: list[LectureReview],
    sessions: list[LectureSessionRecord],
) -> dict[str, Any]:
    """把规则画像和原始证据压缩成 AI 可读、可约束的输入。"""

    recent_reviews: list[dict[str, Any]] = []
    for row in reviews[:12]:
        recent_reviews.append(
            {
                "sectionLabel": _label_for(row.section_id),
                "questionId": row.question_id,
                "summary": _trim(row.summary or "", 80),
                "tags": [
                    _trim(str(tag), 20)
                    for tag in (load_json(row.tags_json, []) or [])[:4]
                ],
                "cautionPoints": [
                    _trim(str(item), 64)
                    for item in (load_json(row.caution_points_json, []) or [])[:4]
                ],
            }
        )

    recent_sessions: list[dict[str, Any]] = []
    for row in sessions[:10]:
        recent_sessions.append(
            {
                "sectionLabel": _label_for(row.section_id),
                "questionId": row.question_id,
                "status": row.status or "",
                "masteryDelta": int(row.mastery_delta or 0),
                "roundCount": int(row.round_count or 0),
                "transcriptPreview": _trim(row.transcript_text or "", 80),
            }
        )

    return {
        "studentName": rule_profile.student_name,
        "grade": rule_profile.grade,
        "ruleProfile": {
            "overview": rule_profile.overview,
            "weakKnowledge": [
                _insight_to_dict(item) for item in rule_profile.weak_knowledge
            ],
            "strengths": [
                _insight_to_dict(item) for item in rule_profile.strengths
            ],
            "learningTraits": [
                _insight_to_dict(item) for item in rule_profile.learning_traits
            ],
            "nextActions": rule_profile.next_actions,
        },
        "recentReviews": recent_reviews,
        "recentSessions": recent_sessions,
    }


def _coerce_evidence_list(raw: Any) -> list[ProfileEvidenceOut]:
    if not isinstance(raw, list):
        return []
    result: list[ProfileEvidenceOut] = []
    for item in raw[:3]:
        if not isinstance(item, dict):
            continue
        label = _trim(str(item.get("label") or ""), 16)
        detail = _trim(str(item.get("detail") or ""), 80)
        if label and detail:
            result.append(ProfileEvidenceOut(label=label, detail=detail))
    return result


def _coerce_ai_insights(raw: Any) -> list[ProfileInsightOut]:
    if not isinstance(raw, list):
        return []
    result: list[ProfileInsightOut] = []
    for item in raw[:3]:
        if not isinstance(item, dict):
            continue
        title = _trim(str(item.get("title") or ""), 16)
        description = _trim(str(item.get("description") or ""), 90)
        evidence = _coerce_evidence_list(item.get("evidence"))
        if title and description and evidence:
            result.append(
                ProfileInsightOut(
                    title=title,
                    description=description,
                    evidence=evidence,
                )
            )
    return result


def _generate_ai_refinement(
    *,
    rule_profile: LearningProfileOut,
    reviews: list[LectureReview],
    sessions: list[LectureSessionRecord],
) -> dict[str, Any] | None:
    """用 DeepSeek 在证据范围内提炼老师式长期画像。失败时返回 None。"""

    if rule_profile.data_points <= 0 or not deepseek_api_key_configured():
        return None

    user_prompt = json.dumps(
        _profile_to_ai_input(
            rule_profile=rule_profile,
            reviews=reviews,
            sessions=sessions,
        ),
        ensure_ascii=False,
    )
    try:
        resp = deepseek_client.with_options(max_retries=0).chat.completions.create(
            model=Config.DEEPSEEK_MODEL,
            messages=[
                {"role": "system", "content": _AI_PROFILE_SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.6,
            max_tokens=_AI_PROFILE_MAX_TOKENS,
            response_format={"type": "json_object"},
            timeout=_AI_PROFILE_TIMEOUT_SECONDS,
            extra_body=deepseek_thinking_disabled_extra_body(),
        )
        raw = (resp.choices[0].message.content or "") if resp.choices else ""
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return None
        return payload
    except Exception as exc:  # noqa: BLE001
        logger.warning("[learning-profile] AI refinement failed: %s", exc)
        return None


def _apply_ai_refinement(
    rule_profile: LearningProfileOut,
    ai_payload: dict[str, Any] | None,
) -> LearningProfileOut:
    if not ai_payload:
        return rule_profile

    ai_summary = _trim(str(ai_payload.get("aiSummary") or ""), 140)
    overview = _trim(str(ai_payload.get("overview") or ""), 96)
    ai_traits = _coerce_ai_insights(ai_payload.get("learningTraits"))
    raw_actions = ai_payload.get("nextActions")
    ai_actions: list[str] = []
    if isinstance(raw_actions, list):
        for item in raw_actions[:3]:
            action = _trim(str(item or ""), 56)
            if action:
                ai_actions.append(action)

    if not ai_summary and not ai_traits and not ai_actions:
        return rule_profile

    merged_traits = [
        *ai_traits,
        *[
            item
            for item in rule_profile.learning_traits
            if item.title not in {trait.title for trait in ai_traits}
        ],
    ][:4]
    merged_actions = [
        *ai_actions,
        *[item for item in rule_profile.next_actions if item not in ai_actions],
    ][:4]

    return rule_profile.model_copy(
        update={
            "overview": overview or rule_profile.overview,
            "ai_summary": ai_summary,
            "profile_source": "rules_ai",
            "learning_traits": merged_traits,
            "next_actions": merged_actions,
        }
    )


def _recent_reviews(db: Session, student_id: int) -> list[LectureReview]:
    return (
        db.query(LectureReview)
        .filter(LectureReview.student_id == student_id)
        .order_by(LectureReview.created_at.desc())
        .limit(40)
        .all()
    )


def _recent_sessions(db: Session, student_id: int) -> list[LectureSessionRecord]:
    return (
        db.query(LectureSessionRecord)
        .filter(LectureSessionRecord.student_id == student_id)
        .order_by(LectureSessionRecord.started_at.desc())
        .limit(40)
        .all()
    )


def build_learning_profile(db: Session, profile: StudentProfile) -> LearningProfileOut:
    """从长期学习数据聚合一份可解释画像。"""

    progress_rows = (
        db.query(LearningProgress)
        .filter(LearningProgress.student_id == profile.id)
        .all()
    )
    reviews = _recent_reviews(db, profile.id)
    sessions = _recent_sessions(db, profile.id)

    practiced = [p for p in progress_rows if int(p.completed_rounds or 0) > 0]
    weak_rows = sorted(
        [p for p in practiced if int(p.mastery_score or 0) < 60],
        key=lambda row: int(row.mastery_score or 0),
    )
    strong_rows = sorted(
        [p for p in practiced if int(p.mastery_score or 0) >= 75],
        key=lambda row: -int(row.mastery_score or 0),
    )

    caution_counter: Counter[str] = Counter()
    tag_counter: Counter[str] = Counter()
    section_cautions: dict[str, list[str]] = {}
    for review in reviews:
        cautions = [
            str(item).strip()
            for item in load_json(review.caution_points_json, []) or []
            if str(item).strip()
        ]
        for caution in cautions:
            caution_counter[caution] += 1
        if cautions:
            section_cautions.setdefault(review.section_id, []).extend(cautions)
        for tag in load_json(review.tags_json, []) or []:
            tag_text = str(tag).strip()
            if tag_text:
                tag_counter[tag_text] += 1

    weak_knowledge: list[ProfileInsightOut] = []
    for row in weak_rows[:4]:
        label = _label_for(row.section_id)
        score = int(row.mastery_score or 0)
        rounds = int(row.completed_rounds or 0)
        cautions = section_cautions.get(row.section_id, [])
        evidence = [
            _evidence("掌握度", f"{score}/100，已完成 {rounds} 轮讲题"),
        ]
        if row.last_summary:
            evidence.append(_evidence("最近小结", _trim(row.last_summary)))
        if cautions:
            evidence.append(_evidence("错因记录", _trim(cautions[0])))
        weak_knowledge.append(
            ProfileInsightOut(
                title=label,
                description=_reason_for(row.section_id),
                evidence=evidence,
                section_id=row.section_id,
            )
        )

    if not weak_knowledge and caution_counter:
        for caution, count in caution_counter.most_common(3):
            weak_knowledge.append(
                ProfileInsightOut(
                    title=_trim(caution, 24),
                    description="最近回顾中反复出现的错因，建议讲题时主动说明。",
                    evidence=[_evidence("出现次数", f"最近回顾中出现 {count} 次")],
                )
            )

    strengths: list[ProfileInsightOut] = []
    for row in strong_rows[:3]:
        label = _label_for(row.section_id)
        score = int(row.mastery_score or 0)
        rounds = int(row.completed_rounds or 0)
        strengths.append(
            ProfileInsightOut(
                title=label,
                description="这一节能稳定讲清，可以尝试更高难度或变式题。",
                evidence=[
                    _evidence("掌握度", f"{score}/100"),
                    _evidence("练习轮数", f"已完成 {rounds} 轮讲题"),
                ],
                section_id=row.section_id,
            )
        )

    incomplete_sessions = [s for s in sessions if s.status != "completed"]
    traits: list[ProfileInsightOut] = []
    if caution_counter:
        caution, count = caution_counter.most_common(1)[0]
        traits.append(
            ProfileInsightOut(
                title="主要错因模式",
                description=_trim(caution, 80),
                evidence=[_evidence("回顾记录", f"最近 {len(reviews)} 条回顾中出现 {count} 次")],
            )
        )
    if weak_rows:
        target = weak_knowledge[0]
        traits.append(
            ProfileInsightOut(
                title="复讲优先级",
                description=f"优先复讲「{target.title}」，先把薄弱规则讲给同伴听。",
                evidence=target.evidence[:2],
            )
        )
    if incomplete_sessions:
        traits.append(
            ProfileInsightOut(
                title="追问承接",
                description="有些讲题轮次还停在继续解释阶段，适合用同伴追问逼出关键条件。",
                evidence=[
                    _evidence("未完成会话", f"最近记录中有 {len(incomplete_sessions)} 次未完成/需继续解释")
                ],
            )
        )
    if tag_counter and not weak_rows:
        tag, count = tag_counter.most_common(1)[0]
        traits.append(
            ProfileInsightOut(
                title="练习偏好",
                description=f"最近更多在练「{tag}」相关题型，可以继续加一点变式迁移。",
                evidence=[_evidence("知识标签", f"最近回顾中出现 {count} 次")],
            )
        )
    if not traits:
        traits.append(
            ProfileInsightOut(
                title="样本积累中",
                description="完成几轮讲题后，系统会从掌握度、错因和追问记录中提炼长期画像。",
                evidence=[_evidence("当前数据", "暂无足够长期记录")],
            )
        )

    next_actions: list[str] = []
    if weak_knowledge:
        next_actions.append(f"今天先复讲「{weak_knowledge[0].title}」，讲完后再做同节变式题。")
    if caution_counter:
        caution, _ = caution_counter.most_common(1)[0]
        next_actions.append(f"讲题时主动补一句：{_trim(caution, 42)}。")
    if strengths:
        next_actions.append(f"「{strengths[0].title}」可以挑战更高难度，验证是否真的迁移。")
    if not next_actions:
        next_actions.append("先完成 2-3 轮基础讲题，系统会开始形成稳定画像。")

    practiced_count = len(practiced)
    total_rounds = sum(int(row.completed_rounds or 0) for row in progress_rows)
    data_points = practiced_count + len(reviews) + len(sessions)
    if practiced_count == 0:
        overview = "目前长期画像还在积累样本。先完成几轮讲题，系统会逐步识别薄弱知识点和常见错因。"
    elif weak_knowledge:
        overview = (
            f"已练 {practiced_count} 个小节、{total_rounds} 轮讲题。"
            f"当前最需要关注「{weak_knowledge[0].title}」。"
        )
    else:
        overview = (
            f"已练 {practiced_count} 个小节、{total_rounds} 轮讲题。"
            "当前没有明显低分小节，可以用变式题继续拉开深度。"
        )

    rule_profile = LearningProfileOut(
        student_name=profile.display_name or "同学",
        grade=profile.grade or "八年级",
        overview=overview,
        data_points=data_points,
        weak_knowledge=[_compact_global_insight(x) for x in weak_knowledge[:2]],
        strengths=[_compact_global_insight(x) for x in strengths[:2]],
        learning_traits=[_compact_global_insight(x) for x in traits[:2]],
        next_actions=next_actions[:3],
    )
    rule_primary = primary_next_action(rule_profile)
    ai_payload = _generate_ai_refinement(
        rule_profile=rule_profile,
        reviews=reviews,
        sessions=sessions,
    )
    final_profile = _apply_ai_refinement(rule_profile, ai_payload)
    recommended_section_id = weak_rows[0].section_id if weak_rows else ""
    return final_profile.model_copy(
        update={
            "recommended_section_id": recommended_section_id,
            # 统一出口用规则层建议，避免多次请求间 AI 非确定性导致文案漂移。
            "primary_next_action": rule_primary,
        }
    )
