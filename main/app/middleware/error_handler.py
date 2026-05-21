import logging
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.exceptions import RequestValidationError

logger = logging.getLogger("app")


async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    """保留 HTTPException 自身的 status_code 和 detail，仅做日志记录。

    必须显式注册，否则下面的 generic_exception_handler 会按 MRO 把 HTTPException
    也压成 500（HTTPException 是 Exception 的子类）。前端 apiFetch 中 `if status === 401`
    跳转登录页的逻辑依赖 401 真实透出。
    """
    if exc.status_code >= 500:
        logger.error(f"HTTP {exc.status_code}: {exc.detail}", exc_info=True)
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=getattr(exc, "headers", None) or {},
    )


async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """保留 422 状态码，让前端能识别字段校验错误。"""
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors()},
    )


async def generic_exception_handler(request: Request, exc: Exception):
    """真·未知异常兜底：500 + 写日志。

    重要：注册顺序不影响 dispatch（Starlette 按异常 MRO 匹配 handler），但必须
    同时注册 StarletteHTTPException + RequestValidationError 的 handler，否则
    HTTPException 也会沿 MRO 命中这里被压成 500，401/404/422 全部变成"Internal
    Server Error"。
    """
    logger.error(f"Unhandled error: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal Server Error", "error": str(exc)},
    )


def register(app):
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_exception_handler(Exception, generic_exception_handler)
