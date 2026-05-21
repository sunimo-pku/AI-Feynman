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
│   ├── AI_CODE_AGENT_BRIEF_ROUND4.md # 第四轮学生语义输入闭环执行指令
│   ├── AI_CODE_AGENT_BRIEF_ROUND5.md # 第五轮多轮追问上下文闭环执行指令
│   ├── AI_CODE_AGENT_BRIEF_ROUND6.md # 第六轮本地掌握度与总结闭环执行指令
│   ├── AI_CODE_AGENT_BRIEF_ROUND7.md # 第七轮本地小题库与下一题轮换执行指令
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

#### 讲题接口（第五轮：本地多轮上下文 + LLM 追问 + Mock fallback；第六轮：completed 后端到端学习沉淀）

`POST /lecture/submit`：学生在 Flutter 客户端点击「提交讲解 / 回答追问」时调用。

> 后端接口与第五轮**完全兼容**，第六轮没有改变契约：客户端拿到 `status: "completed"`
> 之后**本地**沉淀掌握度 / 完成次数 / 本题小结到 `shared_preferences`,
> 不需要后端做账号级持久化。

- **第五轮**起，讲题页在本题内维护一份「最近 6 条」的本地对话历史。
  每次提交时，前端把现存历史 + 本轮 student 发言快照一并放入请求体的
  `history` + `roundIndex` 两个**可选**字段，让 Kimi 准确感知到
  「学生这次到底是在回答上一轮谁的追问」，并据此判定：
    - `status: "needs_explanation"`：还需要继续追问（本轮再下钻一层，不重复上轮原问题）。
    - `status: "completed"` + `masteryDelta: 1`：这一题学生讲清楚了，老师收束。
  前端收到 `completed` 后切到「这一题讲清楚了」收束横幅 + 「再讲一遍 / 下一题」两个对等动作；
  收到 `needs_explanation` 后输入区文案自动从「我刚才是这样讲的」切到
  「回答 X 的追问」，placeholder 也跟着换。
  请求失败重试（点错误条上的「重试」按钮）复用同一个 request 快照，**不**重复追加 student 历史。
- **第四轮**起，请求体携带 `studentSpeechText` / `steps[*].plainText` / `steps[*].latex`
  三个学生语义字段；Prompt 已强化为「优先抓住学生原话、用引号简短照搬关键短语、
  逐条质疑前提条件 / 化简规则 / 计算符号」。
- **第三轮**起，后端 `services/lecture_agent.py` 调用 Moonshot 真实 LLM
  （旗舰模型 `kimi-k2.6` + `thinking.type=disabled` 关思考模式，
  `temperature=0.6`、`response_format=json_object`、`max_retries=0`），
  让 Kimi 在单次调用内扮演小明 / 大雄 / 班长 / 李老师中的 1-2 个角色。
  实测中位数 5-15s 即可返回；后端层 28s timeout + 自动回退 Mock 兜底。
- LLM 返回的 JSON 经过严格校验：`role` 白名单、`text` 非空且 ≤180 中文字符、
  `highlightStepIds` 必须命中请求里真实存在的 `stepId`、`masteryDelta ∈ {-1, 0, 1}`。
  额外防御：第一轮若 LLM 直接返回 `completed` 会被强制改回 `needs_explanation`，
  避免学生还没解释就被收束。
- **任意环节失败**（`KIMI_API_KEY` 缺失、LLM 超时、返回非 JSON、字段不合规、
  history 格式异常）都会**自动回退** Mock 剧本：第 1 轮走第二轮固定追问、
  第 2+ 轮（或带 history）走老师收束 `completed` 文案。**Demo 链路永不中断**,
  后端日志会打 `source=fallback` 便于排查。
- 目前仍仅放行 V1 上线的 16.1 / 16.2 / 16.3 三节。
- 旧客户端（不传 `history` / `roundIndex`）继续兼容：默认 `roundIndex=1`、`history=[]`。

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{
    "sectionId":"pep-g8-down-s16-3",
    "questionId":"mock-radical-003",
    "questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}",
    "studentSpeechText":"因为 12=4×3，4 是完全平方数，所以根号 4=2，最后得到 2 根号 3。",
    "roundIndex":2,
    "history":[
      {"role":"student","displayName":"我",
       "text":"我先把根号十二化成二根号三。",
       "highlightStepIds":["step_1"]},
      {"role":"xiaoming","displayName":"小明",
       "text":"你说把 12 拆成 4×3，为什么 4 可以从根号里出来？",
       "highlightStepIds":["step_1"]}
    ],
    "steps":[
      {"stepId":"step_1","latex":"\\sqrt{12}=2\\sqrt{3}","plainText":"根号12等于2根号3","strokeCount":3,
       "boundingBox":{"x":120,"y":80,"width":360,"height":96}}
    ]
  }'
```

返回：`{ "questionId", "sectionId", "status", "masteryDelta", "turns": [...] }`，
`turns[*].role` 使用稳定英文枚举 `xiaoming / daxiong / monitor / teacher / system`，
`turns[*].highlightStepIds` 一定是请求里 `stepId` 的子集。

错误码：未知 `sectionId` → 404；空 `steps` → 400；字段缺失 / 类型不符 / `roundIndex < 1` → 422。
LLM 失败**不**抛 HTTP 错误，统一在 200 响应内走 Mock fallback。

### Flutter 客户端（Mac 上执行）

```bash
cd main/mobile
flutter pub get
./run_dev.sh    # 需 USB 连接平板；脚本内可改服务器 IP
```

详见 [`docs/MAC_LOCAL_DEV.md`](./docs/MAC_LOCAL_DEV.md)。

#### 学生端学习沉淀（第六轮新增）

- 每当后端返回 `status: "completed"`，讲题页：
  - 落地一条 `SectionProgress` 到 `shared_preferences`
    （key：`ai_feynman.section_progress.v1`）。
  - 累加 `completedRounds`、按 `max(8, masteryDelta * 10)` 加掌握度（上限 100）。
  - 抓取最后一条 teacher / AI turn 作为 `lastSummary`，**不**再调一次 LLM。
  - 展示「本题讲清楚了」小结卡（标题 + 本轮小结 + 「本节掌握度 +X · 当前 N/100」+
    「再讲一遍 / 下一题」两个对等动作；不自动清空画板）。
- 首页可练习小节展示：
  - 未完成：`可练习`
  - 已完成 ≥1 轮：`已完成 N 轮 · X/100`
- 仓库基于 `ChangeNotifier`，首页 / 讲题页 AppBar 徽标自动跟随刷新。
- 任何读 / 写失败仅 `developer.log` 记录，不抛回 UI；学生看到的最差情况是
  「进度回到 0」，**不会**因此看不到课程目录。
- 仅本地持久化，**不**跨设备同步，**不**接后端 DB —— 与第五轮 brief 边界一致。

详细单元测试见 `main/mobile/test/progress_repository_test.dart`：12 个用例覆盖
JSON 容错、`masteryScore` 加分 / 封顶 / fallback 加 8 分、跨章节独立、
重启 App 仍能读出之前进度等关键路径。

#### 本地小题库与下一题轮换（第七轮新增）

- 16.1 / 16.2 / 16.3 三个上线小节内置**每节 3 道题**（基础 / 巩固 / 挑战 各 1 道），
  全部由本地 `MockLectureRepository` 提供，**不**依赖后端题库。
- 每道题携带：
  - `questionId` / `sectionId` / `sectionLabel` / `prompt` / `hint` / `referenceSteps`（与第六轮一致）
  - `difficulty: 1|2|3`（仅开发字段，UI 由 `difficultyLabel` 翻译为「基础 / 巩固 / 挑战」）
  - `tags: List<String>`（1-3 个知识标签，**不**会上送后端，仅供讲题页 chip 展示）
- 讲题页显示：
  - AppBar 标题：`16.3 二次根式的加减 · 第 N / 3 题`
  - 题面卡片：小节名 + 题号 + 难度 chip + 1-3 个知识标签 chip + 题面（LaTeX）+ 提示
  - intro 气泡（李老师开场白）随题号、难度联动
- 下一题 / 再讲一遍：
  - 「下一题」：题目索引 +1，第 3 题再点回到第 1 题（modulo 循环）；同时清空画板、
    高亮、口述、每步说明、LaTeX、`history`、`turns`、`_round`、错误状态、完成态卡片字段。
  - 「再讲一遍」：保留当前题目索引，其他临时态全部清空，老师 intro 后追加一条
    「好，再讲一遍……」system 气泡。
- 后端契约**不变**：`/lecture/submit` 只感知 `questionId` + `questionPrompt`；
  切题后请求体里这两个字段会自然变化，LLM 追问围绕新题面进行（fallback 仍按 section 兜底）。
- 首页可练习小节徽标：未完成时显示 `3 道题 · 可练习`；完成 ≥1 轮后切换为
  `已完成 N 轮 · X/100`；未上线小节继续只显示「即将上线」**不**展示题量。
- 单元测试 `main/mobile/test/mock_lecture_repository_test.dart`：15 个用例覆盖
  题库结构（每节 3 题、难度递增、tags 数量、questionId 唯一）、modulo 循环
  （正/负 index）、未知 section 兜底、`difficultyLabel` 翻译、各小节题面关键短语。

## 环境配置

敏感信息写入根目录 `.env`（已加入 `.gitignore`），参考 `.env.example` 填写。**切勿提交 `.env`。**

## 部署（服务端）

```bash
bash deploy.sh
```

仅重启 Python API；APK 在本地用 `flutter build apk` 构建。
