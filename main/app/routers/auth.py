from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import (
    ParentStudentLink,
    StudentProfile,
    User,
    ensure_student_profile,
    get_db,
    linked_child_profile,
)
from app.middleware.auth import (
    bearer_scheme,
    create_access_token,
    get_current_user,
    get_password_hash,
    require_parent_user,
    require_student_user,
    require_user,
    session_role_from_credentials,
    user_role,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["Auth"])


class RegisterReq(BaseModel):
    username: str
    password: str
    grade: str | None = None
    parent_password: str = Field(..., alias="parentPassword", min_length=6)
    # 兼容旧客户端；新模型忽略 role / childUsername
    role: Literal["student", "parent"] | None = None
    child_username: str | None = Field(None, alias="childUsername")

    model_config = {"populate_by_name": True}


class LoginReq(BaseModel):
    username: str
    password: str
    login_as: Literal["student", "parent"] = Field("student", alias="loginAs")
    parent_password: str | None = Field(None, alias="parentPassword")

    model_config = {"populate_by_name": True}


class SwitchParentReq(BaseModel):
    parent_password: str = Field(..., alias="parentPassword", min_length=6)

    model_config = {"populate_by_name": True}


class UserOut(BaseModel):
    id: int
    username: str
    role: str = "student"

    class Config:
        from_attributes = True


def _user_out(user: User, *, session_role: str) -> UserOut:
    return UserOut(id=user.id, username=user.username, role=session_role)


def _login_response(user: User, *, session_role: str) -> dict:
    token = create_access_token({"sub": user.username, "role": session_role})
    return {
        "token": token,
        "sessionRole": session_role,
        "user": _user_out(user, session_role=session_role).model_dump(),
    }


def _verify_parent_password(user: User, parent_password: str) -> None:
    if not user.parent_password_hash:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Parent password is not set for this account",
        )
    if not verify_password(parent_password, user.parent_password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid parent password",
        )


def _ensure_parent_view_available(db: Session, user: User) -> None:
    if linked_child_profile(db, user) is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="No student profile available for parent view",
        )


@router.post("/register", response_model=UserOut)
async def register(req: RegisterReq, db: Session = Depends(get_db)):
    if req.role == "parent":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Use a single account: register once with account password and parent password.",
        )
    if len(req.username) < 3 or len(req.username) > 32:
        raise HTTPException(status_code=400, detail="Username must be 3-32 characters")
    if len(req.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")
    parent_password = (req.parent_password or "").strip()
    if len(parent_password) < 6:
        raise HTTPException(
            status_code=400,
            detail="Parent password must be at least 6 characters",
        )
    existing = db.query(User).filter(User.username == req.username).first()
    if existing:
        raise HTTPException(status_code=400, detail="Username already taken")

    safe_grade = (req.grade or "八年级").strip() or "八年级"
    user = User(
        username=req.username,
        password_hash=get_password_hash(req.password),
        role="student",
        parent_password_hash=get_password_hash(parent_password),
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
    return _user_out(user, session_role="student")


@router.post("/login")
async def login(req: LoginReq, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == req.username).first()
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid username or password")

    login_as = req.login_as
    if login_as == "parent":
        parent_password = (req.parent_password or "").strip()
        if not parent_password:
            raise HTTPException(status_code=401, detail="Parent password required")
        _verify_parent_password(user, parent_password)
        _ensure_parent_view_available(db, user)
        session_role = "parent"
    else:
        if user_role(user) == "parent":
            raise HTTPException(
                status_code=403,
                detail="This legacy parent account cannot sign in as student. Use parent login.",
            )
        ensure_student_profile(db, user)
        session_role = "student"

    return _login_response(user, session_role=session_role)


@router.post("/switch-parent")
async def switch_to_parent(
    req: SwitchParentReq,
    user: User = Depends(require_student_user),
    db: Session = Depends(get_db),
):
    """已登录学生端：仅凭家长密码切换到家长会话，无需再次输入账号密码。"""
    parent_password = req.parent_password.strip()
    _verify_parent_password(user, parent_password)
    _ensure_parent_view_available(db, user)
    return _login_response(user, session_role="parent")


@router.post("/switch-student")
async def switch_to_student(
    user: User = Depends(require_parent_user),
    db: Session = Depends(get_db),
):
    """已登录家长端：切回学生会话，无需再次输入密码。"""
    if user_role(user) == "parent":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This legacy parent account cannot sign in as student.",
        )
    ensure_student_profile(db, user)
    return _login_response(user, session_role="student")


@router.get("/me", response_model=UserOut)
async def me(
    user: User = Depends(require_user),
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
):
    session_role = session_role_from_credentials(credentials, user)
    return _user_out(user, session_role=session_role)
