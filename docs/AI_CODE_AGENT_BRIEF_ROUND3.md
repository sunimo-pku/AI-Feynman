# AI Code Agent 执行指令：第三轮真实 LLM 结构化追问

> 本页用于约束 AI Code Agent 的第三轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`，并以本页作为本次任务边界。

## 1. 本轮目标

把第二轮的「后端固定 JSON 多 Agent 追问」升级为「后端调用真实 LLM，生成强结构化多 Agent 追问」。

本轮仍不做 SSE、ASR、TTS、OCR。目标是先把多 Agent 剧本生成的 Prompt、JSON Schema、解析校验、失败回退打稳。

最终演示链路：

**课程首页 → 二次根式讲题页 → 学生手写 → 点击提交 → Flutter 调用 `/lecture/submit` → FastAPI 调用 Kimi 生成多 Agent 追问 → 后端校验并返回结构化 JSON → 前端按角色气泡渲染。**

## 2. 严格范围

本轮只做以下事情：

- 复用现有 `POST /lecture/submit` 契约，不改前端请求/响应字段名。
- 后端在 `/lecture/submit` 内部或 service 层调用真实 LLM。
- LLM 输出必须被解析为 `LectureSubmitResponse` 兼容结构。
- Prompt 必须体现「单大模型上下文多角色剧本生成」策略。
- 多 Agent 每轮最多返回 1-2 个角色发言。
- 每条发言必须带 `highlightStepIds`，且只能引用请求中存在的 `stepId`。
- LLM 调用失败、JSON 解析失败、字段不合规时，后端自动回退到第二轮固定 Mock 回复。
- 前端可基本保持不变；只允许为“AI 生成中/Mock 回退提示”做小幅 UI 文案增强。

## 3. 本轮不做

以下能力继续禁止展开：

- 不做 SSE 流式输出。
- 不做真实 ASR 长连接。
- 不做真实 TTS 播放。
- 不做真实 OCR 或数学公式识别。
- 不做数据库持久化。
- 不做掌握度复杂算法。
- 不做家长端、排行榜、晶石、地理定位。
- 不新增登录强依赖，不能让演示链路因为未登录而 401。
- 不大改 Flutter 页面结构。

## 4. 后端设计要求

### 4.1 推荐结构

建议把第二轮 `lecture.py` 中的固定回复逻辑拆轻一点：

- `main/app/routers/lecture.py`：保留请求/响应模型与路由。
- `main/app/services/lecture_agent.py`：新增 LLM Prompt、调用、JSON 解析、fallback 逻辑。

如果为了快速迭代也可以先放在 `lecture.py`，但不要让路由函数变成超长 Prompt 字符串堆砌。

### 4.2 LLM 调用

优先复用现有 `app.services.kimi.chat(...)`，不要新建另一套 OpenAI client。

建议参数：

- `temperature`: `0.4`
- `max_tokens`: `1200`
- `web_search`: `False`
- `enable_tools`: `False`
- `response_format`: 使用 JSON object / JSON schema 能力；如果当前封装不稳定，则在 Prompt 中强约束“只输出 JSON，不要 Markdown”。

如果 `KIMI_API_KEY` 未配置，或 `kimi.chat(...)` 返回“API_KEY 未配置”类提示，必须回退固定 Mock。

## 5. Prompt 要求

System Prompt 必须包含：

- 你是“初中数学费曼学习小组剧本导演”。
- 只围绕人教版八年级下册第十六章二次根式。
- 角色包括：
  - `xiaoming`：基础不牢，追问定义、条件、为什么。
  - `daxiong`：计算粗心，指出运算和化简细节。
  - `monitor`：总结型班长，要求归纳方法。
  - `teacher`：温和老师，负责脚手架式引导和收束。
- 每轮最多选择 1-2 个最合适角色发言。
- 不要一次性公布完整答案。
- 不要嘲讽学生。
- 如果学生步骤太少，优先追问“请补充这一步为什么成立”。
- 所有发言必须对应请求中的真实 `stepId`。
- 只输出 JSON，不输出 Markdown、解释、代码块。

User Prompt 必须包含：

- `sectionId`
- `questionId`
- `questionPrompt`
- `studentSpeechText`
- 所有 `steps` 的 `stepId`、`latex`、`plainText`、`strokeCount`
- 允许引用的 `stepId` 白名单

## 6. LLM 输出契约

LLM 输出必须能转换成以下结构：

```json
{
  "status": "needs_explanation",
  "masteryDelta": 0,
  "turns": [
    {
      "role": "xiaoming",
      "displayName": "小明",
      "text": "我有点疑惑，为什么这里可以把 \\sqrt{12} 拆成 2\\sqrt{3}？能不能说一下用了哪个乘法性质？",
      "highlightStepIds": ["step_1"]
    },
    {
      "role": "teacher",
      "displayName": "李老师",
      "text": "你可以补一句：12 = 4×3，所以 \\sqrt{12}=\\sqrt{4×3}=2\\sqrt{3}。先把这个理由讲清楚。",
      "highlightStepIds": ["step_1"]
    }
  ]
}
```

后端负责补齐或覆盖：

- `questionId`
- `sectionId`
- `turnId`

字段约束：

- `status` 只能是 `needs_explanation` 或 `completed`。
- `masteryDelta` 本轮只能是 `-1`、`0`、`1`。
- `role` 只能是 `xiaoming`、`daxiong`、`monitor`、`teacher`。
- `turns` 长度必须是 1-2。
- `text` 不能为空，长度建议小于 180 个中文字符。
- `highlightStepIds` 必须非空，且全部存在于请求 `steps`。

## 7. 解析与回退

后端必须做防御性解析，但不要把错误暴露给学生：

1. 调用 LLM。
2. 去掉可能的 Markdown 代码块包裹。
3. `json.loads` 解析。
4. 校验 `turns`、`role`、`text`、`highlightStepIds`。
5. 为每条 turn 生成稳定 `turnId`：`turn_1`、`turn_2`。
6. 构造现有 `LectureSubmitResponse`。
7. 任一步失败时，记录日志，然后回退第二轮 `_build_turns(...)` 固定 Mock。

建议响应中不新增必需字段，避免前端被迫改模型。若想让调试可见，可以在后端日志中记录 `source=llm` / `source=fallback`，不要强依赖前端展示。

## 8. 前端要求

前端原则上只做小改：

- 提交按钮文案可以从「提交讲解」临时变为「AI 同伴思考中...」。
- 超时提示可以略微拉长，因为真实 LLM 会比固定 Mock 慢。
- 不要改变 `LectureSubmitResponse` 的解析字段。
- 不要新增本地多 Agent 生成逻辑；生成权应在后端。

如果现有超时时间太短，可把 `LectureService` timeout 调到 `20-30s`，但错误提示仍要友好。

## 9. 验收标准

本轮完成后必须满足：

- 后端 `/health` 正常。
- `POST /lecture/submit` 在配置 `KIMI_API_KEY` 时会调用真实 LLM。
- 返回结构仍与第二轮前端模型兼容。
- 小明/李老师/大雄/班长的发言与当前题目和步骤有关，不是泛泛聊天。
- `highlightStepIds` 能命中前端提交的步骤 ID。
- Kimi API key 缺失、LLM 返回非 JSON、网络失败时，接口仍能返回固定 Mock 回复，不让 Demo 中断。
- 首页、讲题页、手写板、第二轮后端 Mock 行为不被破坏。

## 10. 建议测试

后端：

```bash
cd main
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

验证真实 LLM 或 fallback：

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{"sectionId":"pep-g8-down-s16-3","questionId":"mock-radical-001","questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}","studentSpeechText":"我先把根号十二变成二倍根号三，再把根号二十七变成三倍根号三。","steps":[{"stepId":"step_1","latex":"\\sqrt{12}=2\\sqrt{3}","plainText":"根号12等于2根号3","strokeCount":3,"boundingBox":{"x":120,"y":80,"width":360,"height":96}},{"stepId":"step_2","latex":"\\sqrt{27}=3\\sqrt{3}","plainText":"根号27等于3根号3","strokeCount":3,"boundingBox":{"x":120,"y":190,"width":360,"height":96}}]}'
```

前端：

```bash
cd main/mobile
flutter analyze
flutter run
```

如果本地无法调用真实 Kimi，必须至少验证 fallback 路径可用，并说明原因。

## 11. 完成后同步

- 更新 `README.md`：说明 `/lecture/submit` 已支持真实 LLM 结构化追问，并保留 Mock fallback。
- 更新 `DEMO_SCRIPT.md`：追加“真实 AI 多 Agent 追问”演示条目。
- 若踩到 Kimi JSON 输出、API key、超时、字段校验或 fallback 坑，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
