"""简易内存限流。

设计要点：
  - **维度从 IP+path 改为 user_id**：原方案 30 次/分钟/IP+path 在多用户共享 NAT
    或单用户连续多轮对话时会被秒爆（一次正常面试 30 轮就到上限）。改成按
    user_id 限流后，未登录请求依赖 require_user 自然被 401 拦掉。
  - **路径白名单跳过**：`/assets`、`/health`、`/static` 完全不限流；
    `/interview/chat`、`/chat/stream` 这种长会话流式接口给单独的高额度桶，
    避免聊几轮就被 429。
  - 公网评审常见的"同一 IP 几个测试号"场景下，分桶后互不干扰。

生产环境应迁到 Redis；限时项目内存方案足够，进程重启会清零（非问题）。
"""
import time
from collections import defaultdict
from fastapi import Request, HTTPException, status
from jose import jwt, JWTError

from app.middleware.auth import SECRET_KEY, ALGORITHM

_rate_records: dict[str, list[float]] = defaultdict(list)

WINDOW_SECONDS = 60
DEFAULT_MAX = 60          # 普通接口 60 次/分钟
CHAT_MAX = 240            # 对话 / 流式接口 240 次/分钟（≈每秒 4 次）
CHAT_PATH_PREFIXES = ("/interview/chat", "/chat", "/tts", "/asr")
SKIP_PATHS = ("/assets", "/health", "/static", "/docs", "/openapi.json")


def _extract_user_id(request: Request) -> str:
    """从 Bearer token 中解出 username。失败则回退到 client IP。"""
    auth = request.headers.get("authorization") or request.headers.get("Authorization")
    if auth and auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1].strip()
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
            sub = payload.get("sub")
            if sub:
                return f"u:{sub}"
        except JWTError:
            pass
    return f"ip:{request.client.host if request.client else 'unknown'}"


async def rate_limit_middleware(request: Request, call_next):
    path = request.url.path
    if any(path.startswith(p) for p in SKIP_PATHS):
        return await call_next(request)

    is_chat = any(path.startswith(p) for p in CHAT_PATH_PREFIXES)
    max_requests = CHAT_MAX if is_chat else DEFAULT_MAX
    bucket = "chat" if is_chat else "default"

    actor = _extract_user_id(request)
    now = time.time()
    key = f"{actor}:{bucket}"
    cutoff = now - WINDOW_SECONDS

    records = [ts for ts in _rate_records[key] if ts > cutoff]
    if len(records) >= max_requests:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Rate limit exceeded ({max_requests}/{WINDOW_SECONDS}s). Please slow down.",
        )

    records.append(now)
    _rate_records[key] = records
    return await call_next(request)


def reset_limiter():
    """测试/重启时清空限流记录"""
    _rate_records.clear()
