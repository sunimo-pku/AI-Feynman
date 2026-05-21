import os
import json
from datetime import datetime
from sqlalchemy import create_engine, Column, Integer, String, Text, DateTime, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker, Session

DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "app.db")
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

engine = create_engine(f"sqlite:///{DB_PATH}", connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


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
    system_prompt = Column(Text, default="你是一位资深的体制内公文写作专家（老秘）。你熟练掌握《党政机关公文处理工作条例》及各类公文（如请示、报告、通知、通报、函、纪要、讲话稿等）的格式规范和行文风格。\n【核心要求】\n1. 绝对拒绝“AI味”：严禁使用“首先、其次、最后、总而言之、希望这能帮到你”等AI常见套话。严禁使用轻浮、热情的语气词（如“好的！”“没问题！”）。直接输出公文正文，不要有任何开场白或结束语。\n2. 语言风格：文字精炼、准确、庄重、规范。多用短句，少用长定语。善用公文常用词汇（如：切实、抓好、贯彻、落实、统筹、协调、推进、深化等）。\n3. 逻辑结构：层次分明，逻辑严密。标题和层级序号必须严格符合公文规范（如：一、 （一） 1. （1））。\n4. 政治站位：具备极高的政治敏锐性，表述必须符合当前党和国家的方针政策，客观中立，不带个人感情色彩。")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


# Create tables on import
Base.metadata.create_all(bind=engine)


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
