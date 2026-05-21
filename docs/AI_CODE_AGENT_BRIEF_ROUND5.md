# AI Code Agent 执行指令：第五轮多轮追问上下文闭环

> 本页用于约束 AI Code Agent 的第五轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND3.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND4.md`，并以本页作为本次任务边界。

## 1. 当前进度判断

前四轮已经完成：

- Flutter 学生端首页与二次根式讲题页骨架。
- 手写板书写、撤销、清空、提交与步骤高亮。
- `POST /lecture/submit` 后端接口。
- 后端真实 Kimi / LLM 结构化多 Agent 追问，并保留 Mock fallback。
- 讲题页支持学生手动输入口述讲解、步骤说明和可选 LaTeX。
- 后端 Prompt 已优先使用学生原话与步骤文字生成追问。

当前主要短板：每次提交仍偏“单轮”。学生看到小明/李老师追问后，即使再补一句解释，后端也缺少清晰的“上一轮 AI 问了什么、学生这次是在回答哪个问题”的上下文。

## 2. 本轮目标

做出一个真正的本地多轮追问闭环：

**学生提交解题 → AI 追问 → 学生输入回答 / 补充说明 → 再次提交 → 后端基于上一轮追问与学生新回答继续追问或判定完成。**

本轮仍不做数据库持久化，只在当前讲题页内维护本地会话上下文。

## 3. 严格范围

本轮只做以下事情：

- 前端在讲题页维护当前题目的本地对话历史。
- `/lecture/submit` 请求体新增可选 `history` 和 `roundIndex` 字段。
- 后端 Prompt 使用 `history` 判断学生本轮是在继续讲题，还是在回答上一轮追问。
- 前端增加“回答追问”的轻量输入状态，复用第四轮的口述输入区即可。
- 后端可根据学生回答返回：
  - `status: "needs_explanation"`：还需要继续追问。
  - `status: "completed"`：这一题讲清楚了。
- 前端收到 `completed` 后强化“我懂了 / 下一题”状态。
- 保持第三轮 LLM fallback、第四轮语义输入都不被破坏。

## 4. 本轮不做

以下能力继续禁止展开：

- 不做数据库持久化。
- 不做账号级学习历史。
- 不做复杂掌握度算法。
- 不做 ASR、OCR、TTS。
- 不做 SSE 流式输出。
- 不做家长端、排行榜、晶石、地理定位。
- 不重写讲题页整体架构。
- 不把通用 `/chat` 会话系统混入讲题闭环。

## 5. 数据契约

继续复用 `POST /lecture/submit`，只新增可选字段，避免破坏旧请求。

### 5.1 请求体

```json
{
  "sectionId": "pep-g8-down-s16-3",
  "questionId": "mock-radical-001",
  "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}",
  "studentSpeechText": "我刚才回答小明：因为 12 可以拆成 4×3，4 是完全平方数，所以能提出 2。",
  "roundIndex": 2,
  "history": [
    {
      "role": "student",
      "displayName": "我",
      "text": "我先把根号十二化成二根号三，再把根号二十七化成三根号三。",
      "highlightStepIds": ["step_1", "step_2"]
    },
    {
      "role": "xiaoming",
      "displayName": "小明",
      "text": "你刚才说“把 12 拆成 4×3”，为什么 4 可以从根号里出来？",
      "highlightStepIds": ["step_1"]
    }
  ],
  "steps": [
    {
      "stepId": "step_1",
      "latex": "\\sqrt{12}=2\\sqrt{3}",
      "plainText": "根号12化成2根号3",
      "strokeCount": 3,
      "boundingBox": {
        "x": 120,
        "y": 80,
        "width": 360,
        "height": 96
      }
    }
  ]
}
```

字段约束：

- `roundIndex` 可选，默认 `1`。
- `history` 可选，默认 `[]`。
- `history[].role` 允许：`student`、`xiaoming`、`daxiong`、`monitor`、`teacher`、`system`。
- `history` 只传当前题目的最近 6-10 条，避免 Prompt 过长。
- 不改现有 `LectureSubmitResponse` 字段。

### 5.2 响应体

继续沿用第三轮响应：

```json
{
  "questionId": "mock-radical-001",
  "sectionId": "pep-g8-down-s16-3",
  "status": "completed",
  "masteryDelta": 1,
  "turns": [
    {
      "turnId": "turn_1",
      "role": "teacher",
      "displayName": "李老师",
      "text": "这次解释清楚了：你说出了 4 是完全平方数，所以 \\sqrt{4×3}=2\\sqrt{3}。这一题可以收束。",
      "highlightStepIds": ["step_1"]
    }
  ]
}
```

## 6. 前端要求

### 6.1 本地历史维护

在讲题页维护一个当前题目的历史列表：

- 学生每次提交时，把本轮 `studentSpeechText` 和步骤说明整理成一条 `student` 历史。
- 后端返回的 `turns` 也追加到本地历史。
- 下一次提交时，把最近若干条历史放进请求体。
- 点击「下一题 / 重新开始」时清空历史。

### 6.2 交互文案

AI 追问后，输入区文案从“我刚才是这样讲的”切换为类似：

- 「回答小明 / 李老师的追问」
- placeholder：「例如：因为 12=4×3，4 是完全平方数，所以可以把 2 提出来……」

收到 `status: "completed"` 后：

- 显示温和完成反馈，例如「这一题讲清楚了」。
- 主按钮可以变成「下一题」或「再讲一遍」。
- 不要自动清空手写板，给学生留时间看高亮和回顾。

### 6.3 防止重复历史

- 重试同一个失败请求时，不要重复追加同一条 student 历史。
- 可以在请求构造时临时生成 history，而不是先写入全局列表。
- 只有请求成功后，再把本轮 student 记录和 AI turns 一起落入本地历史。

## 7. 后端要求

### 7.1 Pydantic 模型

在 `routers/lecture.py` 中新增可选模型：

- `LectureHistoryItem`
- `round_index: int = Field(1, alias="roundIndex", ge=1)`
- `history: list[LectureHistoryItem] = Field(default_factory=list)`

保持旧请求仍能通过。

### 7.2 Prompt 使用历史

在 `lecture_agent.py` 中把 history 加入 user prompt：

- 明确标注“这是上一轮追问与学生回答历史”。
- 如果最近一条 AI 追问后学生给出回答，本轮应优先判断回答是否解释清楚。
- 如果学生回答到位，可以返回 `completed` 和 `masteryDelta: 1`。
- 如果回答仍含糊，继续返回 `needs_explanation`。

### 7.3 Fallback 逻辑

Fallback 也要支持多轮的基本体感：

- `roundIndex <= 1`：保持现有固定追问。
- `roundIndex > 1`：优先返回老师收束或继续追问的固定回复，不要每次都重复第一轮同样问题。
- 不要因为 history 缺失或格式异常直接 500；可忽略坏 history 并继续。

## 8. Prompt 关键规则

System/User Prompt 需要增加这些约束：

- 如果学生是在回答上一轮追问，要先评价“有没有答到点上”。
- 不要重复上一轮已经问过的问题，除非学生没有回答。
- 如果学生解释了规则和前提条件，就用老师收束并设置 `completed`。
- 如果学生只给结论没讲原因，继续追问“为什么”。
- 每轮仍最多 1-2 条 Agent 发言。
- 所有 `highlightStepIds` 仍只能引用当前 steps 里的真实 ID。

## 9. 验收标准

本轮完成后必须满足：

- 第一轮提交后，AI 给出追问。
- 学生在输入区回答追问后再次提交，请求体包含上一轮 AI 追问历史。
- 后端第二轮回复不再像第一次那样重复问同一个问题。
- 当学生回答清楚时，后端可以返回 `status: "completed"`。
- 前端收到 `completed` 后显示完成状态，并提供下一步操作。
- 请求失败重试不会重复追加历史。
- 点击「下一题 / 重新开始」会清空本题历史、输入区和高亮。
- 第三轮 LLM fallback、第四轮学生语义输入仍可用。

## 10. 建议测试

后端：

```bash
cd main
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

用 curl 验证第二轮上下文：

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{"sectionId":"pep-g8-down-s16-3","questionId":"mock-radical-001","questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}","studentSpeechText":"因为 12=4×3，4 是完全平方数，所以根号4可以变成2，最后得到2根号3。","roundIndex":2,"history":[{"role":"student","displayName":"我","text":"我先把根号十二化成二根号三。","highlightStepIds":["step_1"]},{"role":"xiaoming","displayName":"小明","text":"你说把 12 拆成 4×3，为什么 4 可以从根号里出来？","highlightStepIds":["step_1"]}],"steps":[{"stepId":"step_1","latex":"\\sqrt{12}=2\\sqrt{3}","plainText":"根号12化成2根号3","strokeCount":3,"boundingBox":{"x":120,"y":80,"width":360,"height":96}}]}'
```

前端：

```bash
cd main/mobile
flutter analyze
flutter run
```

如果无法真机运行，至少通过后端日志或临时调试输出确认第二轮请求包含 `history` 和 `roundIndex`。

## 11. 完成后同步

- 更新 `README.md`：说明讲题页已支持本地多轮追问上下文。
- 更新 `DEMO_SCRIPT.md`：追加“学生回答追问后继续一轮”的演示条目。
- 若踩到历史重复、Prompt 过长、completed 状态、重试重复提交等问题，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
