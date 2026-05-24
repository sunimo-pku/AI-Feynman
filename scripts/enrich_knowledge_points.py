#!/usr/bin/env python3
"""Inject knowledge points into curriculum + attach questions to knowledgePointId.

V1 seed strategy (per section):
  - 3 knowledge points, 1 question each (keeps 270 total questions).
  - 16.x sections prefer titles from data/knowledge/*_chunks.json when present.
  - Other sections use question tags or 核心概念 / 巩固应用 / 易错辨析.
"""

from __future__ import annotations

import json
import shutil
from collections import defaultdict
from copy import deepcopy
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CURRICULUM = ROOT / "data" / "curriculum" / "pep-junior-math.json"
QUESTIONS = ROOT / "data" / "questions" / "pep-junior-math-questions.json"
KNOWLEDGE_DIR = ROOT / "data" / "knowledge"
MOBILE_CUR = ROOT / "main" / "mobile" / "assets" / "curriculum" / "pep-junior-math.json"
MOBILE_Q = ROOT / "main" / "mobile" / "assets" / "questions" / "pep-junior-math-questions.json"

DIFF_LABELS = {1: "核心概念", 2: "巩固应用", 3: "易错辨析"}

# 八年级下册 · 第十六章：按教材树显式定义知识点（非「一题一知识点」）。
CH16_SECTION_KNOWLEDGE_POINTS: dict[str, list[str]] = {
    "pep-g8-down-s16-1": [
        "二次根式的定义",
        "二次根式有意义的条件",
    ],
    "pep-g8-down-s16-2": [
        "二次根式的性质与化简",
        "最简二次根式",
        "二次根式的乘除法",
        "分母有理化",
    ],
    "pep-g8-down-s16-3": [
        "同类二次根式",
        "二次根式的加减法",
        "二次根式的混合运算",
        "二次根式的化简求值",
        "二次根式的应用",
    ],
}

# 现有 curated 题 → 知识点序号（1-based）；变式题 qid-d2/d3 继承同一映射。
CH16_QUESTION_KP_ORDER: dict[str, int] = {
    "q-s16-1-kp1-001": 1,
    "q-s16-1-kp1-002": 1,
    "q-s16-1-kp1-003": 1,
    "q-s16-1-kp2-004": 2,
    "q-s16-1-kp2-005": 2,
    "q-s16-1-kp2-006": 2,
    "q-s16-1-kp2-007": 2,
    "q-s16-2-kp1-001": 1,
    "q-s16-2-kp1-002": 1,
    "q-s16-2-kp1-003": 1,
    "q-s16-2-kp1-004": 1,
    "q-s16-2-kp1-005": 1,
    "q-s16-2-kp2-001": 2,
    "q-s16-2-kp2-002": 2,
    "q-s16-2-kp3-001": 3,
    "q-s16-2-kp3-002": 3,
    "q-s16-2-kp3-003": 3,
    "q-s16-2-kp3-004": 3,
    "q-s16-2-kp3-005": 3,
    "q-s16-2-kp4-001": 4,
    "q-s16-2-kp4-002": 4,
    "q-s16-2-kp4-003": 4,
    "q-s16-2-kp4-004": 4,
    "q-s16-2-kp4-005": 4,
}


def _base_question_id(question_id: str) -> str:
    qid = str(question_id or "").strip()
    for suffix in ("-d2", "-d3"):
        if qid.endswith(suffix):
            return qid[: -len(suffix)]
    return qid


def _build_ch16_knowledge_points(section_id: str) -> list[dict[str, Any]]:
    titles = CH16_SECTION_KNOWLEDGE_POINTS.get(section_id) or []
    return [
        {
            "id": f"{section_id}-kp{order}",
            "title": title,
            "label": title,
            "order": order,
        }
        for order, title in enumerate(titles, start=1)
    ]


def _attach_ch16_question_kp(section_id: str, question: dict[str, Any]) -> None:
    base_id = _base_question_id(str(question.get("questionId") or ""))
    order = CH16_QUESTION_KP_ORDER.get(base_id)
    if order is None:
        return
    titles = CH16_SECTION_KNOWLEDGE_POINTS.get(section_id) or []
    if order < 1 or order > len(titles):
        return
    title = titles[order - 1]
    question["knowledgePointId"] = f"{section_id}-kp{order}"
    question["knowledgePointLabel"] = title


def _load_chunks_by_section() -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = defaultdict(list)
    if not KNOWLEDGE_DIR.exists():
        return out
    for path in sorted(KNOWLEDGE_DIR.glob("*_chunks.json")):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if not isinstance(raw, list):
            continue
        for item in raw:
            if not isinstance(item, dict):
                continue
            sid = str(item.get("sectionId") or item.get("section_id") or "").strip()
            title = str(item.get("title") or "").strip()
            if sid and title:
                out[sid].append(item)
    return out


def _kp_title(section_id: str, question: dict[str, Any], order: int, chunks: list[dict]) -> str:
    if order - 1 < len(chunks):
        return str(chunks[order - 1].get("title") or "").strip() or DIFF_LABELS.get(order, f"知识点{order}")
    tags = question.get("tags") or []
    if isinstance(tags, list) and tags:
        first = str(tags[0]).strip()
        if first:
            return first
    return DIFF_LABELS.get(order, f"知识点{order}")


def enrich() -> tuple[int, int]:
    curriculum = json.loads(CURRICULUM.read_text(encoding="utf-8"))
    qdoc = json.loads(QUESTIONS.read_text(encoding="utf-8"))
    questions: list[dict[str, Any]] = qdoc.get("questions") or []
    by_section: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for q in questions:
        sid = str(q.get("sectionId") or "").strip()
        qid = str(q.get("questionId") or "").strip()
        if sid and qid and not qid.endswith("-d2") and not qid.endswith("-d3"):
            by_section[sid].append(q)
    for lst in by_section.values():
        lst.sort(key=lambda x: int(x.get("difficulty") or 1))

    chunks_by_section = _load_chunks_by_section()
    kp_total = 0

    for book in curriculum.get("books") or []:
        for chapter in book.get("chapters") or []:
            for section in chapter.get("sections") or []:
                sid = str(section.get("id") or "").strip()
                if sid in CH16_SECTION_KNOWLEDGE_POINTS:
                    kps = _build_ch16_knowledge_points(sid)
                    section["knowledgePoints"] = kps
                    kp_total += len(kps)
                    for q in questions:
                        if str(q.get("sectionId") or "").strip() != sid:
                            continue
                        _attach_ch16_question_kp(sid, q)
                    continue

                section_qs = by_section.get(sid, [])
                chunks = chunks_by_section.get(sid, [])
                kps = []
                for i, q in enumerate(section_qs, start=1):
                    title = _kp_title(sid, q, i, chunks)
                    kp_id = f"{sid}-kp{i}"
                    kps.append(
                        {
                            "id": kp_id,
                            "title": title,
                            "label": title,
                            "order": i,
                        }
                    )
                    q["knowledgePointId"] = kp_id
                    q.setdefault("knowledgePointLabel", title)
                    kp_total += 1
                section["knowledgePoints"] = kps

    # 每个知识点补齐巩固 / 挑战难度题（同知识点、更高 difficulty），供星级自适应出题。
    existing_ids = {str(q.get("questionId") or "").strip() for q in questions}
    extra: list[dict[str, Any]] = []
    for q in questions:
        kp_id = str(q.get("knowledgePointId") or "").strip()
        qid = str(q.get("questionId") or "").strip()
        if not kp_id or not qid or qid.endswith("-d2") or qid.endswith("-d3"):
            continue
        base_diff = int(q.get("difficulty") or 1)
        for tier, label in ((2, "巩固"), (3, "挑战")):
            if tier <= base_diff:
                continue
            new_id = f"{qid}-d{tier}"
            if new_id in existing_ids:
                continue
            clone = deepcopy(q)
            clone["questionId"] = new_id
            clone["difficulty"] = tier
            prompt = str(clone.get("prompt") or "").strip()
            if prompt and label not in prompt:
                clone["prompt"] = f"{prompt}（{label}练）"
            extra.append(clone)
    questions.extend(extra)

    qdoc["questions"] = questions
    qdoc["questionPolicy"] = (
        "Questions belong to knowledge points; each KP has up to 3 difficulty "
        "tiers (基础/巩固/挑战) for star-based adaptive assignment."
    )

    CURRICULUM.write_text(
        json.dumps(curriculum, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    QUESTIONS.write_text(
        json.dumps(qdoc, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    MOBILE_CUR.parent.mkdir(parents=True, exist_ok=True)
    MOBILE_Q.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CURRICULUM, MOBILE_CUR)
    shutil.copyfile(QUESTIONS, MOBILE_Q)
    return kp_total, len(questions)


def main() -> None:
    kp_total, q_total = enrich()
    print(f"enriched knowledgePoints={kp_total} questions={q_total}")


if __name__ == "__main__":
    main()
