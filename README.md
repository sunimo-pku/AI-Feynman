# New Project

基于 `workspace` 复用的全栈项目骨架：FastAPI 后端 + React 前端，API Key 与开发规范已从原项目继承。

## 技术栈

- **后端**：Python 3.10 + FastAPI + Uvicorn + SQLAlchemy (SQLite)
- **前端**：Vite + React 19 + TypeScript + Tailwind CSS v4
- **大模型**：Kimi k2.6 + DeepSeek V4 Pro
- **语音**：豆包 TTS + ASR（火山引擎）
- **认证**：bcrypt + JWT

## 项目结构

```
.
├── README.md
├── AGENTS.md               # AI 协作规范（从 workspace 复制）
├── FRONTEND_STYLE.md         # 前端视觉规范（从 workspace 复制）
├── deploy.sh                 # 一键部署脚本
├── .env                      # API Key（已从 workspace 复制，勿提交 Git）
├── .env.example              # 环境变量模板
├── .gitignore
└── main/
    ├── app/                  # FastAPI 后端
    │   ├── main.py
    │   ├── config.py
    │   ├── db.py
    │   ├── routers/          # chat / tts / asr / auth / sessions / upload
    │   ├── services/         # kimi / volc_tts / volc_asr / agent_tools
    │   └── middleware/       # auth / error_handler / rate_limit
    ├── frontend/             # React 前端
    ├── data/                 # SQLite 与上传文件（运行时生成）
    └── logs/                 # 运行日志
```

## 快速启动

### 开发模式

```bash
# 后端
cd /root/new-project/main
uvicorn app.main:app --host 127.0.0.1 --port 8001 --reload

# 前端（另开终端）
cd /root/new-project/main/frontend
npm install
npm run dev
```

### 生产部署

```bash
bash /root/new-project/deploy.sh
```

> 默认监听 `127.0.0.1:8001`，与 workspace 的 8000 端口错开，避免冲突。

## 环境变量

`.env` 已从 `workspace` 复制，包含 Kimi / DeepSeek / 火山语音 / JWT 配置。如需重新填写，参考 `.env.example`：

```bash
KIMI_API_KEY=sk-xxx
DEEPSEEK_API_KEY=sk-xxx
VOLC_API_KEY=xxx
JWT_SECRET_KEY=your-secret-key-here
```

## 内置页面

| 路径 | 说明 |
| --- | --- |
| `/` | 登录 |
| `/register` | 注册 |
| `/chat` | AI 对话（SSE 流式） |
| `/tts` | 语音合成 |
| `/diagnostics` | API 连通性诊断 |
| `/health` | 健康检查 |

## 从 workspace 继承的内容

- `.env` / `.env.example` / `.gitignore`
- `AGENTS.md` / `FRONTEND_STYLE.md`
- 后端服务层（Kimi、豆包 TTS/ASR、函数调用框架）
- 中间件（JWT 认证、错误处理、限流）
- 前端 UI 组件与 Chat / TTS / 登录等页面骨架
