# AI 费曼（AI-Feynman）

面向**初中数学**的定制化「费曼学习法」**Android App**（平板优先）。学生通过手写 + 语音向多个 AI 角色讲题，系统追踪掌握度；家长端查看弱项与学习回放。

> 详细产品规划见 [`项目规划/planV1.md`](./项目规划/planV1.md)

## 技术栈

| 层 | 技术 |
|----|------|
| 客户端 | **Flutter / Dart**（Android） |
| 服务端 | **Python FastAPI** + Uvicorn |
| LLM / 语音 | Kimi API、豆包 TTS / ASR |

## 仓库

[github.com/sunimo-pku/AI-Feynman](https://github.com/sunimo-pku/AI-Feynman)

## 目录结构

```
.
├── README.md
├── AGENTS.md                 # AI 协作规范（Agent 修改前必读）
├── MOBILE_STYLE.md           # Flutter 客户端视觉与交互规范
├── DEMO_SCRIPT.md            # Demo 演示提纲（随功能追加）
├── deploy.sh                 # 后端一键部署
├── docs/
│   └── MAC_LOCAL_DEV.md      # Mac + 平板本地预览（Cursor 协作必读）
├── .env.example              # 环境变量模板（复制为 .env 后填写）
├── 项目规划/
│   └── planV1.md             # 产品规划 V1
├── data/
│   └── curriculum/
│       └── pep-junior-math.json   # 人教版初中数学目录（6 册 · 29 章 · 90 节）
├── scripts/
│   └── build_curriculum.py   # 重新生成课程目录 JSON
└── main/
    ├── app/                  # Python 后端 API
    └── mobile/               # Flutter Android 客户端
```

## 核心设计原则

| 原则 | 说明 |
|------|------|
| 目录做全 | 人教版初一～初三完整章节树，用户可浏览全貌 |
| 内容先填一块 | V1 仅 **第十六章 二次根式**（八年级下册 · 16.1～16.3）有题目、讲题流程与掌握度 |
| 快速迭代 | 先做可验证原型，找真实用户反馈后再改 |
| 做深做窄 | 一个完整闭环 > 多个半成品功能 |

## 本地开发

> **Mac + 安卓平板预览**：见 [`docs/MAC_LOCAL_DEV.md`](./docs/MAC_LOCAL_DEV.md)（含「复制给 Cursor」指令）

### 后端 API

```bash
cd main
pip install -r requirements.txt   # 若尚未安装依赖
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

健康检查：`http://127.0.0.1:8001/health`  
API 文档：`http://127.0.0.1:8001/docs`

### Flutter 客户端（Mac 上执行）

```bash
cd main/mobile
flutter pub get
./run_dev.sh    # 需 USB 连接平板；脚本内可改服务器 IP
```

详见 [`docs/MAC_LOCAL_DEV.md`](./docs/MAC_LOCAL_DEV.md)。

## 环境配置

敏感信息写入根目录 `.env`（已加入 `.gitignore`），参考 `.env.example` 填写。**切勿提交 `.env`。**

## 部署（服务端）

```bash
bash deploy.sh
```

仅重启 Python API；APK 在本地用 `flutter build apk` 构建。
