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
│   ├── AI_CODE_AGENT_BRIEF.md # 首个可演示小闭环的 AI 执行指令
│   ├── AI_CODE_AGENT_BRIEF_ROUND2.md # 第二轮后端 Mock 闭环执行指令
│   ├── AI_CODE_AGENT_BRIEF_ROUND3.md # 第三轮真实 LLM 结构化追问执行指令
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

#### 讲题接口（第三轮：真实 LLM 多 Agent 追问 + Mock fallback）

`POST /lecture/submit`：学生在 Flutter 客户端点击「提交讲解」时调用。

- **第三轮**起，后端 `services/lecture_agent.py` 会调用 Moonshot 真实 LLM
  （非思考模型 `moonshot-v1-32k`，温度 0.4，`response_format=json_object`），
  让 Kimi 在单次调用内扮演小明 / 大雄 / 班长 / 李老师中的 1-2 个角色，
  生成针对学生当前 `steps` 的强结构化追问。
- LLM 返回的 JSON 会经过严格校验：`role` 白名单、`text` 非空且 ≤180 中文字符、
  `highlightStepIds` 必须命中请求里真实存在的 `stepId`、`masteryDelta ∈ {-1, 0, 1}`。
- **任意环节失败**（`KIMI_API_KEY` 缺失、LLM 超时、返回非 JSON、字段不合规）
  都会**自动回退**到第二轮的固定 Mock 剧本，**Demo 链路永不中断**，
  后端日志会打 `source=fallback` 便于排查。
- 目前仍仅放行 V1 上线的 16.1 / 16.2 / 16.3 三节。

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{
    "sectionId":"pep-g8-down-s16-3",
    "questionId":"mock-radical-003",
    "questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}",
    "studentSpeechText":"我先把根号十二变成二倍根号三，再把根号二十七变成三倍根号三。",
    "steps":[
      {"stepId":"step_1","latex":"\\sqrt{12}=2\\sqrt{3}","plainText":"根号12等于2根号3","strokeCount":3,
       "boundingBox":{"x":120,"y":80,"width":360,"height":96}},
      {"stepId":"step_2","latex":"\\sqrt{27}=3\\sqrt{3}","plainText":"根号27等于3根号3","strokeCount":3,
       "boundingBox":{"x":120,"y":190,"width":360,"height":96}}
    ]
  }'
```

返回：`{ "questionId", "sectionId", "status", "masteryDelta", "turns": [...] }`，
`turns[*].role` 使用稳定英文枚举 `xiaoming / daxiong / monitor / teacher / system`，
`turns[*].highlightStepIds` 一定是请求里 `stepId` 的子集。

错误码：未知 `sectionId` → 404；空 `steps` → 400；字段缺失 / 类型不符 → 422。
LLM 失败**不**抛 HTTP 错误，统一在 200 响应内走 Mock fallback。

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
