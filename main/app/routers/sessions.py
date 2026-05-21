from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session
from app.db import get_db, ChatSession, serialize_messages, deserialize_messages
from app.middleware.auth import require_user, User

router = APIRouter(prefix="/sessions", tags=["Sessions"])


class SessionCreate(BaseModel):
    title: str = "新会话"
    messages: list[dict] = []
    model: str = "kimi-k2.6"
    temperature: float = 1.0
    top_p: float = 0.95
    max_tokens: int = 8192
    system_prompt: str = ""


class SessionUpdate(BaseModel):
    title: str | None = None
    messages: list[dict] | None = None
    model: str | None = None
    temperature: float | None = None
    top_p: float | None = None
    max_tokens: int | None = None
    system_prompt: str | None = None


@router.get("")
async def list_sessions(user: User = Depends(require_user), db: Session = Depends(get_db)):
    sessions = db.query(ChatSession).filter(ChatSession.user_id == user.id).order_by(ChatSession.updated_at.desc()).all()
    return [
        {
            "id": s.id,
            "title": s.title,
            "messages": deserialize_messages(s.messages_json),
            "model": s.model,
            "temperature": float(s.temperature),
            "topP": float(s.top_p),
            "maxTokens": int(s.max_tokens),
            "systemPrompt": s.system_prompt or "",
            "createdAt": s.created_at.isoformat() if s.created_at else None,
            "updatedAt": s.updated_at.isoformat() if s.updated_at else None,
        }
        for s in sessions
    ]


@router.post("")
async def create_session(req: SessionCreate, user: User = Depends(require_user), db: Session = Depends(get_db)):
    s = ChatSession(
        user_id=user.id,
        title=req.title,
        messages_json=serialize_messages(req.messages),
        model=req.model,
        temperature=str(req.temperature),
        top_p=str(req.top_p),
        max_tokens=str(req.max_tokens),
        system_prompt="",
    )
    db.add(s)
    db.commit()
    db.refresh(s)
    return {"id": s.id}


@router.put("/{session_id}")
async def update_session(session_id: int, req: SessionUpdate, user: User = Depends(require_user), db: Session = Depends(get_db)):
    s = db.query(ChatSession).filter(ChatSession.id == session_id, ChatSession.user_id == user.id).first()
    if not s:
        return {"error": "Session not found"}
    if req.title is not None:
        s.title = req.title
    if req.messages is not None:
        s.messages_json = serialize_messages(req.messages)
    if req.model is not None:
        s.model = req.model
    if req.temperature is not None:
        s.temperature = str(req.temperature)
    if req.top_p is not None:
        s.top_p = str(req.top_p)
    if req.max_tokens is not None:
        s.max_tokens = str(req.max_tokens)
    if req.system_prompt is not None:
        s.system_prompt = req.system_prompt
    db.commit()
    return {"ok": True}


@router.delete("/{session_id}")
async def delete_session(session_id: int, user: User = Depends(require_user), db: Session = Depends(get_db)):
    s = db.query(ChatSession).filter(ChatSession.id == session_id, ChatSession.user_id == user.id).first()
    if not s:
        return {"error": "Session not found"}
    db.delete(s)
    db.commit()
    return {"ok": True}
