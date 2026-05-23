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
        if sid:
            by_section[sid].append(q)
    for lst in by_section.values():
        lst.sort(key=lambda x: int(x.get("difficulty") or 1))

    chunks_by_section = _load_chunks_by_section()
    kp_total = 0

    for book in curriculum.get("books") or []:
        for chapter in book.get("chapters") or []:
            for section in chapter.get("sections") or []:
                sid = str(section.get("id") or "").strip()
                section_qs = by_section.get(sid, [])
                chunks = chunks_by_section.get(sid, [])
                kps: list[dict[str, Any]] = []
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
            clone = deepcopy(q)
            clone["questionId"] = f"{qid}-d{tier}"
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
