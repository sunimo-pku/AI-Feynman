# AI Code Agent 执行指令：第二轮后端 Mock 闭环

> 本页用于约束 AI Code Agent 的第二轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`，并以本页作为本次任务边界。

## 1. 本轮目标

把第一轮的「本地 Mock 多 Agent 追问」升级为「前端调用后端 API，后端返回固定结构化 JSON」。

本轮仍不接真实 LLM、ASR、TTS、OCR。目标是先稳定前后端契约、请求状态、错误提示和讲题会话结构。

最终演示链路：

**课程首页 → 二次根式讲题页 → 学生手写 → 点击提交 → Flutter 调用 FastAPI `/lecture/submit` → 后端返回固定多 Agent 追问 → 前端渲染角色气泡与步骤高亮占位。**

## 2. 严格范围

本轮只做以下事情：

- 新增后端讲题路由，例如 `main/app/routers/lecture.py`。
- 在 `main/app/main.py` 注册该路由。
- 新增 `POST /lecture/submit` 接口。
- 接口接收章节、题目、手写步骤占位数据。
- 接口返回固定 JSON，至少包含小明和李老师两条追问。
- Flutter 讲题页提交时调用后端接口，不再直接读取本地 Mock 回复。
- 前端保留清晰的 loading、成功、失败状态。
- 后端不可用或接口失败时，前端显示温和错误提示，并允许重新提交。

## 3. 本轮不做

以下能力继续禁止展开：

- 不接真实 Kimi / LLM。
- 不做 SSE 流式输出。
- 不做真实 ASR 长连接。
- 不做真实 TTS 播放。
- 不做真实 OCR 或数学公式识别。
- 不做数据库持久化。
- 不做复杂掌握度算法。
- 不做家长端、排行榜、晶石、地理定位。
- 不重构第一轮已完成页面的大结构，除非是接入 API 必须的小改。

## 4. 后端接口契约

### 4.1 请求

建议接口：

```http
POST /lecture/submit
Content-Type: application/json
```

请求体：

```json
{
  "sectionId": "pep-g8-down-ch16-sec1",
  "questionId": "mock-radical-001",
  "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}",
  "studentSpeechText": "",
  "steps": [
    {
      "stepId": "step_1",
      "latex": "",
      "plainText": "",
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

字段说明：

- `sectionId`：课程目录中的小节 ID。
- `questionId`：当前题目 ID，第二轮允许继续使用 mock ID。
- `questionPrompt`：题干文本。
- `studentSpeechText`：预留给 ASR 的文本字段，本轮可以为空。
- `steps`：手写步骤占位数据，本轮不要求真实 OCR。
- `boundingBox`：预留给前端高亮定位，本轮可以由前端生成简单占位值。

### 4.2 响应

响应体必须保持强结构，方便后续替换为真实 LLM：

```json
{
  "questionId": "mock-radical-001",
  "sectionId": "pep-g8-down-ch16-sec1",
  "status": "needs_explanation",
  "masteryDelta": 0,
  "turns": [
    {
      "turnId": "turn_1",
      "role": "xiaoming",
      "displayName": "小明",
      "text": "我有点疑惑，\\sqrt{12} 为什么可以变成 2\\sqrt{3}？这里用了什么规律？",
      "highlightStepIds": ["step_1"]
    },
    {
      "turnId": "turn_2",
      "role": "teacher",
      "displayName": "李老师",
      "text": "这个问题很好。你可以试着把 12 拆成 4×3，再说明为什么 4 能从根号里出来。",
      "highlightStepIds": ["step_1"]
    }
  ]
}
```

约束：

- `role` 使用稳定英文枚举：`xiaoming`、`teacher`，后续可扩展 `daxiong`、`monitor`。
- `highlightStepIds` 必须是数组，即使为空也返回 `[]`。
- 接口参数错误使用合适的 HTTP 状态码，不要返回 200 + `{"error": ...}`。

## 5. 前端接入要求

- 所有接口路径统一经过 `main/mobile/lib/config/api_config.dart`。
- 可在 `main/mobile/lib/services/api_service.dart` 增加 `submitLecture(...)`，或新增职责更清晰的 `lecture_service.dart`。
- 建议新增数据模型，例如 `LectureSubmitRequest`、`LectureSubmitResponse`、`AgentTurn`。
- 点击「提交讲解」时：
  - 按钮进入 loading 状态，避免重复提交。
  - 成功后把 `turns` 渲染成角色气泡。
  - 失败后显示错误提示，不清空手写内容。
- 保留第一轮本地 Mock 题目，但多 Agent 回复应来自后端接口。

## 6. 后端实现要求

- 使用 FastAPI + Pydantic 定义请求/响应模型。
- 固定 JSON 可以直接在路由函数中返回，或封装到轻量 service。
- 路由命名保持清晰：`lecture` 表示讲题闭环，不要复用通用 `/chat`。
- 本轮不依赖鉴权也可以，但如果现有 Flutter 尚未登录，不能因为 `require_user` 阻塞演示。
- 代码里不要硬编码生产域名或本机 IP。

## 7. 验收标准

本轮完成后必须满足：

- 后端启动后，`/health` 正常。
- `POST /lecture/submit` 可以用固定请求体返回结构化 JSON。
- Flutter 讲题页点击「提交讲解」会真实请求后端。
- 请求成功后，页面显示小明和李老师两条追问。
- 请求过程中有 loading 反馈。
- 后端关闭或接口失败时，页面有明确错误提示，并能重新提交。
- 不影响首页课程目录、未上线章节置灰、手写板撤销/清空能力。

## 8. 建议测试

后端：

```bash
cd main
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

用 API 文档或 curl 验证：

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{"sectionId":"pep-g8-down-ch16-sec1","questionId":"mock-radical-001","questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}","studentSpeechText":"","steps":[{"stepId":"step_1","latex":"","plainText":"","strokeCount":3,"boundingBox":{"x":120,"y":80,"width":360,"height":96}}]}'
```

前端：

```bash
cd main/mobile
flutter analyze
flutter run
```

如本地环境暂时无法跑 Flutter，至少完成 `flutter analyze` 或说明未验证原因。

## 9. 完成后同步

- 更新 `README.md`：说明第二轮已有 `/lecture/submit` 后端 Mock 闭环。
- 更新 `DEMO_SCRIPT.md`：追加“后端 Mock 多 Agent 追问”演示条目。
- 若接口字段、错误处理或 Flutter 真机调试踩坑，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
