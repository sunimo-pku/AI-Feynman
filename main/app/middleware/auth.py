import os
import secrets
import logging
from datetime import datetime, timedelta
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import JWTError, jwt
import bcrypt
from sqlalchemy.orm import Session
from app.db import get_db, User

logger = logging.getLogger("app")

# JWT_SECRET_KEY 必须从环境变量读取。
# 缺失时不再使用硬编码的"占位密钥"——那是写在公开 Git 仓库里的字符串，
# 任何看过代码的人都能伪造任意用户的 token。这里改成进程启动时随机生成
# 一段 32 字节密钥并打 warning，迫使运维补 .env；同时旧 token 在重启后会全部失效。
_env_secret = os.getenv("JWT_SECRET_KEY", "").strip()
if _env_secret:
    SECRET_KEY = _env_secret
else:
    SECRET_KEY = secrets.token_hex(32)
    logger.warning(
        "JWT_SECRET_KEY not set in environment. Generated an ephemeral key for this "
        "process — all issued tokens will be invalidated on restart. Set JWT_SECRET_KEY "
        "in .env for production."
    )

ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 7
# bcrypt 上限 72 字节，超长密码会被静默截断 → 不同的"长密码"hash 一致是安全隐患。
# 这里在 hash / verify 前一律截断到 72 字节并保持一致。
BCRYPT_MAX_BYTES = 72

bearer_scheme = HTTPBearer(auto_error=False)


def _truncate_for_bcrypt(password: str) -> bytes:
    raw = password.encode("utf-8")
    return raw[:BCRYPT_MAX_BYTES]


def verify_password(plain: str, hashed: str) -> bool:
    """密码校验。包 try/except：旧的或损坏的 hash 会让 bcrypt 抛 ValueError，
    不能让它冒泡变成 500，否则前端登录失败时无法引导用户去重置。"""
    try:
        return bcrypt.checkpw(_truncate_for_bcrypt(plain), hashed.encode("utf-8"))
    except (ValueError, TypeError) as e:
        logger.warning(f"Password verification failed: {e}")
        return False


def get_password_hash(password: str) -> str:
    return bcrypt.hashpw(_truncate_for_bcrypt(password), bcrypt.gensalt()).decode("utf-8")


def create_access_token(data: dict, expires_delta: timedelta | None = None) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def decode_token(token: str) -> dict | None:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
) -> User | None:
    if not credentials:
        return None
    payload = decode_token(credentials.credentials)
    if not payload:
        return None
    username: str | None = payload.get("sub")
    if not username:
        return None
    return db.query(User).filter(User.username == username).first()


async def require_user(
    user: User | None = Depends(get_current_user),
) -> User:
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user
