"""SQLAlchemy 数据层。

第十轮（V1 总收口）新增：

- `StudentProfile`：学生侧个人资料，1:1 关联 `User`；
- `LearningProgress`：按 (student, section) 记录掌握度与完成轮数；
- `LectureReview`：每完成一道题写一条「回顾摘要」；
- `LectureSessionRecord`：每次实时讲题会话的元数据（不存原始音频）。

设计要点：

- 不复用旧 `ChatSession`，讲题闭环走独立业务表，避免历史遗留字段干扰；
- 因为 SQLite `create_all()` 不会给老表加列，所有「新增字段」走轻量迁移
  `_run_lightweight_migrations`：启动时 PRAGMA 检查列是否存在，缺失则 `ALTER TABLE`；
- 不在表里直接保存音频；只保留转写文本、结构化摘要、JSON 列表；
- JSON 列统一用 `Text` + `json.dumps/loads`，避免引入 SQLAlchemy JSON 类型
  在某些 SQLite 版本上的兼容性问题。
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime
from typing import Any

from sqlalchemy import (
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    create_engine,
    inspect,
    text,
)
from sqlalchemy.orm import Session, declarative_base, sessionmaker

logger = logging.getLogger("app")

DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "app.db")
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

engine = create_engine(f"sqlite:///{DB_PATH}", connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


# ---------------------------------------------------------------------------
# 旧表（保留以兼容历史登录账号 / 旧调试会话）
# ---------------------------------------------------------------------------


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    password_hash = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class ChatSession(Base):
    __tablename__ = "chat_sessions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    title = Column(String, default="新会话")
    messages_json = Column(Text, default="[]")
    model = Column(String, default="deepseek-v4-pro")
    temperature = Column(String, default="1.0")
    top_p = Column(String, default="0.95")
    max_tokens = Column(String, default="8192")
    system_prompt = Column(Text, default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


# ---------------------------------------------------------------------------
# 第十轮：学习业务表
# ---------------------------------------------------------------------------


class StudentProfile(Base):
    """学生侧个人资料。

    V1 不做复杂的家长-孩子绑定：一个 `User` 即视为一个学生主体；家长端登录
    后通过同一个 `user_id` 读自己的学习数据。后续上线「家长账号下挂多个
    孩子」时，只需要把 `user_id` 改成「家长 user_id」并新增一个
    `parent_user_id` 字段，整体表结构不动。
    """

    __tablename__ = "student_profiles"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True, unique=True)
    display_name = Column(String(64), default="同学")
    grade = Column(String(32), default="八年级")
    school_name = Column(String(96), default="AI 费曼实验校")
    province = Column(String(32), default="山东省")
    city = Column(String(32), default="济南市")
    district = Column(String(32), default="历下区")
    equipped_title = Column(String(96), default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class LearningProgress(Base):
    """按 (student, section) 记录掌握度与完成轮数。

    与前端 `SectionProgress`（`shared_preferences`）字段保持一致，
    便于 `/learning/progress/sync` 做行级 upsert。
    """

    __tablename__ = "learning_progress"
    __table_args__ = (
        UniqueConstraint("student_id", "section_id", name="uq_progress_student_section"),
    )

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    completed_rounds = Column(Integer, default=0)
    mastery_score = Column(Integer, default=0)
    last_practiced_at = Column(DateTime, nullable=True)
    last_summary = Column(Text, default="")
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class LectureReview(Base):
    """每完成一道题写一条回顾摘要。

    家长端 dashboard 的「最近讲题回顾」直接读这张表，按
    `created_at` 倒序取最近 N 条。
    """

    __tablename__ = "lecture_reviews"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    # 客户端生成的本地 id（`questionId-millis`），用来去重，与服务端自增主键
    # 解耦。多次同步同一条记录走 ON CONFLICT 更新而不是新插。
    client_id = Column(String(96), nullable=False, index=True, unique=True)
    section_id = Column(String(64), nullable=False, index=True)
    question_id = Column(String(64), nullable=False, index=True)
    question_prompt = Column(Text, default="")
    difficulty = Column(Integer, default=1)
    tags_json = Column(Text, default="[]")
    summary = Column(Text, default="")
    agent_highlights_json = Column(Text, default="[]")
    caution_points_json = Column(Text, default="[]")
    created_at = Column(DateTime, default=datetime.utcnow)


class LectureSessionRecord(Base):
    """每次实时讲题会话的元数据。

    不保存原始音频；只保存：
    - 学生侧 ASR 转写拼接文本（去掉静音段）；
    - 步骤的 stepId / latex / plainText 列表；
    - AI turns 的角色 / 文本 / highlight。

    V1 仅用于「将来 debug 时回放讲题脉络」和家长端「最近一次精彩讲题」。
    """

    __tablename__ = "lecture_session_records"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=True, index=True)
    session_id = Column(String(64), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    question_id = Column(String(64), nullable=False, index=True)
    question_prompt = Column(Text, default="")
    status = Column(String(32), default="needs_explanation")
    transcript_text = Column(Text, default="")
    steps_json = Column(Text, default="[]")
    turns_json = Column(Text, default="[]")
    mastery_delta = Column(Integer, default=0)
    round_count = Column(Integer, default=0)
    started_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime, nullable=True)


class LectureReplayRecord(Base):
    """讲题过程回放：音频片段、笔迹时间轴、气泡时间轴。

    第十一轮不强制合成 MP4；用结构化时间轴满足「可回放」底线。
    """

    __tablename__ = "lecture_replay_records"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    session_id = Column(String(64), nullable=False, index=True, unique=True)
    section_id = Column(String(64), nullable=False, index=True)
    question_id = Column(String(64), nullable=False, index=True)
    question_prompt = Column(Text, default="")
    audio_base64_chunks_json = Column(Text, default="[]")
    ink_timeline_json = Column(Text, default="[]")
    turns_timeline_json = Column(Text, default="[]")
    duration_ms = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)


class SectionPower(Base):
    __tablename__ = "section_power"
    __table_args__ = (
        UniqueConstraint("student_id", "section_id", name="uq_power_student_section"),
    )

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    power_score = Column(Integer, default=0)
    rank_tier = Column(String(32), default="青铜")
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class PowerEvent(Base):
    __tablename__ = "power_events"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    delta = Column(Integer, default=0)
    reason = Column(String(64), default="")
    ref_id = Column(String(96), default="")
    created_at = Column(DateTime, default=datetime.utcnow)


class LeaderboardSnapshot(Base):
    __tablename__ = "leaderboard_snapshots"
    __table_args__ = (
        UniqueConstraint(
            "scope", "section_id", "week_id", "student_id",
            name="uq_leaderboard_scope_week_student",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    scope = Column(String(24), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    week_id = Column(String(16), nullable=False, index=True)
    rank = Column(Integer, default=0)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    power_score = Column(Integer, default=0)
    title_label = Column(String(96), default="")
    created_at = Column(DateTime, default=datetime.utcnow)


class BountyAttempt(Base):
    __tablename__ = "bounty_attempts"
    __table_args__ = (
        UniqueConstraint("student_id", "challenge_id", name="uq_bounty_student_challenge"),
    )

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    challenge_id = Column(String(64), nullable=False, index=True)
    section_id = Column(String(64), nullable=False, index=True)
    circled_correctly = Column(Integer, default=0)
    transcript_text = Column(Text, default="")
    crystal_reward = Column(Integer, default=0)
    power_reward = Column(Integer, default=0)
    completed_at = Column(DateTime, default=datetime.utcnow)


class CrystalWallet(Base):
    __tablename__ = "crystal_wallets"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True, unique=True)
    balance = Column(Integer, default=0)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class CrystalLedger(Base):
    __tablename__ = "crystal_ledgers"

    id = Column(Integer, primary_key=True, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    amount = Column(Integer, default=0)
    reason = Column(String(64), default="")
    ref_id = Column(String(96), default="")
    balance_after = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)


class RedeemOrder(Base):
    __tablename__ = "redeem_orders"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(String(64), nullable=False, index=True, unique=True)
    sku_id = Column(String(64), nullable=False, index=True)
    student_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    status = Column(String(32), default="pending")
    crystal_cost = Column(Integer, default=0)
    address_json = Column(Text, default="{}")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class ParentStudentLink(Base):
    __tablename__ = "parent_student_links"
    __table_args__ = (
        UniqueConstraint("parent_user_id", "student_profile_id", name="uq_parent_student_link"),
    )

    id = Column(Integer, primary_key=True, index=True)
    parent_user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    student_profile_id = Column(Integer, ForeignKey("student_profiles.id"), nullable=False, index=True)
    nickname = Column(String(64), default="")
    created_at = Column(DateTime, default=datetime.utcnow)


# ---------------------------------------------------------------------------
# 启动初始化 + 轻量迁移
# ---------------------------------------------------------------------------


def _run_lightweight_migrations() -> None:
    """SQLite `create_all()` 不会给老表加列；这里手动补字段。

    每次启动都执行：用 PRAGMA table_info 拿到列名集合，缺失就 `ALTER TABLE`。
    单 `try/except` 包住每条 ALTER：跑过的就跳过，不让一次失败阻塞启动。

    本轮新增字段：
    - `lecture_session_records.mastery_delta`
    - `lecture_session_records.round_count`

    旧字段保留兼容旧 DB；以后增字段时同样按这个套路加分支即可。
    """

    with engine.connect() as conn:
        # 检查 lecture_session_records 的列；本次新增的几个字段在旧库不存在
        def _columns(table: str) -> list[str]:
            try:
                return [row[1] for row in conn.execute(text(f"PRAGMA table_info({table})"))]
            except Exception as e:  # noqa: BLE001
                logger.warning("[db-migrate] inspect %s failed: %s", table, e)
                return []

        cols = _columns("lecture_session_records")

        if cols:  # 表已存在
            if "mastery_delta" not in cols:
                try:
                    conn.execute(
                        text(
                            "ALTER TABLE lecture_session_records "
                            "ADD COLUMN mastery_delta INTEGER DEFAULT 0"
                        )
                    )
                    logger.info("[db-migrate] added lecture_session_records.mastery_delta")
                except Exception as e:  # noqa: BLE001
                    logger.warning("[db-migrate] add mastery_delta failed: %s", e)
            if "round_count" not in cols:
                try:
                    conn.execute(
                        text(
                            "ALTER TABLE lecture_session_records "
                            "ADD COLUMN round_count INTEGER DEFAULT 0"
                        )
                    )
                    logger.info("[db-migrate] added lecture_session_records.round_count")
                except Exception as e:  # noqa: BLE001
                    logger.warning("[db-migrate] add round_count failed: %s", e)

        profile_cols = _columns("student_profiles")
        profile_additions = {
            "school_name": "ALTER TABLE student_profiles ADD COLUMN school_name VARCHAR(96) DEFAULT 'AI 费曼实验校'",
            "province": "ALTER TABLE student_profiles ADD COLUMN province VARCHAR(32) DEFAULT '山东省'",
            "city": "ALTER TABLE student_profiles ADD COLUMN city VARCHAR(32) DEFAULT '济南市'",
            "district": "ALTER TABLE student_profiles ADD COLUMN district VARCHAR(32) DEFAULT '历下区'",
            "equipped_title": "ALTER TABLE student_profiles ADD COLUMN equipped_title VARCHAR(96) DEFAULT ''",
        }
        if profile_cols:
            for col, sql in profile_additions.items():
                if col in profile_cols:
                    continue
                try:
                    conn.execute(text(sql))
                    logger.info("[db-migrate] added student_profiles.%s", col)
                except Exception as e:  # noqa: BLE001
                    logger.warning("[db-migrate] add student_profiles.%s failed: %s", col, e)

        try:
            conn.commit()
        except Exception:  # noqa: BLE001
            pass


def init_db() -> None:
    """创建尚未存在的表 + 执行轻量迁移。"""

    Base.metadata.create_all(bind=engine)
    _run_lightweight_migrations()


# 启动时建表，避免老路径依赖「import 时副作用建表」失效。
init_db()


# ---------------------------------------------------------------------------
# 依赖注入 / JSON helper
# ---------------------------------------------------------------------------


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def serialize_messages(messages: list[dict]) -> str:
    return json.dumps(messages, ensure_ascii=False)


def deserialize_messages(data: str) -> list[dict]:
    try:
        return json.loads(data)
    except Exception:
        return []


def dump_json(value: Any) -> str:
    """统一的 JSON 序列化：ensure_ascii=False，避免中文被转 `\\uxxxx` 撑爆磁盘。"""

    try:
        return json.dumps(value, ensure_ascii=False)
    except Exception:  # noqa: BLE001
        return "null"


def load_json(raw: str | None, default: Any) -> Any:
    if not raw:
        return default
    try:
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return default


def ensure_student_profile(db: Session, user: User) -> StudentProfile:
    """登录后第一次访问学习接口时自动建一份 student profile。

    幂等：第二次调用直接返回已有行。`display_name` 默认取 username,
    后续如果家长端要改名再走 PATCH 接口（V1 暂不实现）。
    """

    profile = (
        db.query(StudentProfile)
        .filter(StudentProfile.user_id == user.id)
        .first()
    )
    if profile is not None:
        return profile
    profile = StudentProfile(
        user_id=user.id,
        display_name=user.username,
        grade="八年级",
        school_name="AI 费曼实验校",
        province="山东省",
        city="济南市",
        district="历下区",
    )
    db.add(profile)
    db.commit()
    db.refresh(profile)
    return profile
