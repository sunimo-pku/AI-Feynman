from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    ParentStudentLink,
    StudentProfile,
    User,
    ensure_student_profile,
    get_db,
)
from app.middleware.auth import (
    create_access_token,
    get_current_user,
    get_password_hash,
    user_role,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["Auth"])


class RegisterReq(BaseModel):
    username: str
    password: str
    grade: str | None = None
    role: Literal["student", "parent"] = "student"
    parent_password: str | None = Field(None, alias="parentPassword")
    child_username: str | None = Field(None, alias="childUsername")

    model_config = {"populate_by_name": True}


class LoginReq(BaseModel):
    username: str
    password: str
    parent_password: str | None = Field(None, alias="parentPassword")

    model_config = {"populate_by_name": True}


class UserOut(BaseModel):
    id: int
    username: str
    role: str = "student"

    class Config:
        from_attributes = True


def _user_out(user: User) -> UserOut:
    return UserOut(id=user.id, username=user.username, role=user_role(user))


@router.post("/register", response_model=UserOut)
async def register(req: RegisterReq, db: Session = Depends(get_db)):
    if len(req.username) < 3 or len(req.username) > 32:
        raise HTTPException(status_code=400, detail="Username must be 3-32 characters")
    if len(req.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")
    existing = db.query(User).filter(User.username == req.username).first()
    if existing:
        raise HTTPException(status_code=400, detail="Username already taken")

    if req.role == "parent":
        parent_password = (req.parent_password or "").strip()
        child_username = (req.child_username or "").strip()
        if len(parent_password) < 6:
            raise HTTPException(
                status_code=400,
                detail="Parent password must be at least 6 characters",
            )
        if len(child_username) < 3:
            raise HTTPException(
                status_code=400,
                detail="Child username is required for parent registration",
            )
        child_user = db.query(User).filter(User.username == child_username).first()
        if child_user is None:
            raise HTTPException(status_code=404, detail="Child username not found")
        if user_role(child_user) != "student":
            raise HTTPException(
                status_code=400,
                detail="Child account must be a student account",
            )
        child_profile = ensure_student_profile(db, child_user)
        if (
            db.query(ParentStudentLink)
            .filter(ParentStudentLink.student_profile_id == child_profile.id)
            .first()
        ):
            raise HTTPException(
                status_code=400,
                detail="This child is already linked to another parent account",
            )
        user = User(
            username=req.username,
            password_hash=get_password_hash(req.password),
            role="parent",
            parent_password_hash=get_password_hash(parent_password),
        )
        db.add(user)
        db.flush()
        db.add(
            ParentStudentLink(
                parent_user_id=user.id,
                student_profile_id=child_profile.id,
                nickname=child_profile.display_name or child_user.username,
            )
        )
        db.commit()
        db.refresh(user)
        return _user_out(user)

    safe_grade = (req.grade or "八年级").strip() or "八年级"
    user = User(
        username=req.username,
        password_hash=get_password_hash(req.password),
        role="student",
    )
    db.add(user)
    db.flush()
    db.add(
        StudentProfile(
            user_id=user.id,
            display_name=user.username,
            grade=safe_grade,
        )
    )
    db.commit()
    db.refresh(user)
    return _user_out(user)


@router.post("/login")
async def login(req: LoginReq, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == req.username).first()
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    role = user_role(user)
    if role == "parent":
        parent_password = (req.parent_password or "").strip()
        if not parent_password or not user.parent_password_hash:
            raise HTTPException(status_code=401, detail="Parent password required")
        if not verify_password(parent_password, user.parent_password_hash):
            raise HTTPException(status_code=401, detail="Invalid parent password")
        link = (
            db.query(ParentStudentLink)
            .filter(ParentStudentLink.parent_user_id == user.id)
            .first()
        )
        if link is None:
            raise HTTPException(
                status_code=403,
                detail="Parent account is not linked to a child",
            )
    token = create_access_token({"sub": user.username, "role": role})
    return {"token": token, "user": _user_out(user).model_dump()}


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)):
    if not user:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return _user_out(user)
