#!/usr/bin/env python3
"""Settle weekly leaderboard snapshots.

Idempotent by `(scope, section_id, week_id, student_id)`: rerunning the script
updates rank/score/title instead of inserting duplicates.
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "main"))

from app.db import (  # noqa: E402
    LeaderboardSnapshot,
    SectionPower,
    SessionLocal,
    StudentProfile,
    init_db,
)

SCOPES = {
    "school": "school_name",
    "district": "district",
    "city": "city",
    "province": "province",
}


def _week_id(dt: datetime) -> str:
    iso = dt.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def main() -> None:
    init_db()
    week_id = _week_id(datetime.utcnow() - timedelta(days=7))
    db = SessionLocal()
    try:
        powers = db.query(SectionPower).all()
        profiles = {p.id: p for p in db.query(StudentProfile).all()}
        touched = 0
        section_ids = sorted({p.section_id for p in powers})
        for section_id in section_ids:
            section_powers = [p for p in powers if p.section_id == section_id]
            for scope, attr in SCOPES.items():
                buckets: dict[str, list[SectionPower]] = {}
                for power in section_powers:
                    profile = profiles.get(power.student_id)
                    area = str(getattr(profile, attr, "") or "") if profile else ""
                    if not area:
                        continue
                    buckets.setdefault(area, []).append(power)
                for area, rows in buckets.items():
                    rows.sort(key=lambda r: int(r.power_score or 0), reverse=True)
                    for rank, row in enumerate(rows, start=1):
                        profile = profiles.get(row.student_id)
                        title = f"{area} · {section_id} 第 {rank} 名"
                        snap = (
                            db.query(LeaderboardSnapshot)
                            .filter(
                                LeaderboardSnapshot.scope == scope,
                                LeaderboardSnapshot.section_id == section_id,
                                LeaderboardSnapshot.week_id == week_id,
                                LeaderboardSnapshot.student_id == row.student_id,
                            )
                            .first()
                        )
                        if snap is None:
                            snap = LeaderboardSnapshot(
                                scope=scope,
                                section_id=section_id,
                                week_id=week_id,
                                student_id=row.student_id,
                            )
                            db.add(snap)
                        snap.rank = rank
                        snap.power_score = int(row.power_score or 0)
                        snap.title_label = title
                        if rank == 1 and profile is not None:
                            profile.equipped_title = title
                        touched += 1
        db.commit()
        print(f"settled week={week_id} snapshot_rows={touched}")
    finally:
        db.close()


if __name__ == "__main__":
    main()
