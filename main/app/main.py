import os
import logging
from datetime import datetime
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.branding import API_TITLE, DISPLAY_NAME
from app.routers import (
    asr,
    assignments,
    auth,
    chat,
    learning,
    lecture,
    lecture_live,
    ocr,
    parent,
    round11,
    sessions,
    tts,
    upload,
)
from app.middleware import error_handler, rate_limit

# 日志配置
os.makedirs("logs", exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.FileHandler(f"logs/app_{datetime.now().strftime('%Y%m%d')}.log"),
        logging.StreamHandler(),
    ],
)

app = FastAPI(
    title=API_TITLE,
    description=f"{DISPLAY_NAME} · Flutter Android 客户端后端（FastAPI + DeepSeek / 豆包语音）",
    version="0.2.0",
)

# 注册中间件
error_handler.register(app)

# CORS：允许同源及本地开发环境
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 限流：防止 API 额度被刷
app.middleware("http")(rate_limit.rate_limit_middleware)

# 注册路由
app.include_router(chat.router)
app.include_router(tts.router)
app.include_router(asr.router)
app.include_router(auth.router)
app.include_router(sessions.router)
app.include_router(upload.router)
app.include_router(lecture.router)
app.include_router(lecture_live.router)
# 第十轮：学习同步、家长端、OCR 兜底
app.include_router(learning.router)
app.include_router(parent.router)
app.include_router(assignments.router)
app.include_router(ocr.router)
app.include_router(round11.router)

@app.get("/")
async def root():
    return {
        "name": API_TITLE,
        "displayName": DISPLAY_NAME,
        "docs": "/docs",
        "health": "/health",
    }


@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now().isoformat()}
