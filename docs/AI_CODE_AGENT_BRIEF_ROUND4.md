# AI Code Agent 执行指令：第四轮学生语义输入闭环

> 本页用于约束 AI Code Agent 的第四轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND3.md`，并以本页作为本次任务边界。

## 1. 当前进度判断

前三轮已经完成：

- Flutter 学生端首页与二次根式讲题页骨架。
- 手写板书写、撤销、清空、提交。
- `POST /lecture/submit` 后端接口。
- 后端固定 Mock fallback。
- 后端真实 Kimi / LLM 结构化多 Agent 追问。
- 前端接收 `turns` 并渲染角色气泡与步骤高亮。

当前主要短板：前端提交给后端的 `studentSpeechText`、`steps[].latex`、`steps[].plainText` 基本为空。LLM 虽然已经接入，但它看不到学生真正“怎么讲、怎么写”，只能根据题目和笔画数猜追问。

## 2. 本轮目标

在不接真实 ASR/OCR 的前提下，补上“学生语义输入”：

**学生手写步骤 → 手动输入/编辑自己的讲解文字和步骤文字 → 点击提交 → 后端 LLM 基于这些语义内容生成更贴近当前解法的多 Agent 追问。**

本轮本质是为后续 ASR/OCR 铺接口和 UI，不追求自动识别。

## 3. 严格范围

本轮只做以下事情：

- 在讲题页新增一个轻量的「讲解文字」输入区，对应 `studentSpeechText`。
- 在讲题页允许学生为当前手写步骤补充文字说明，对应 `steps[].plainText`。
- 可选：允许学生为步骤补充 LaTeX 文本，对应 `steps[].latex`。
- 提交时把这些语义字段随现有 `LectureSubmitRequest` 一起发给 `/lecture/submit`。
- 后端 Prompt 已经读取这些字段时，只做必要的小修；如果还没有，要确保 LLM Prompt 明确使用它们。
- 保持 `/lecture/submit` 请求/响应契约不破坏第三轮。
- 保持真实 LLM 失败时 fallback 可用。

## 4. 本轮不做

以下能力继续禁止展开：

- 不做真实 ASR。
- 不做真实 OCR。
- 不做 TTS 播放。
- 不做 SSE 流式输出。
- 不做数据库持久化。
- 不做图片上传识题。
- 不做家长端、排行榜、晶石、地理定位。
- 不重构讲题页整体布局，只在现有页面上增加必要输入区。

## 5. 前端设计要求

### 5.1 讲解文字输入

在 `main/mobile/lib/pages/lecture_page.dart` 中新增一个适合平板的输入区域：

- 标签建议：「我刚才是这样讲的」
- placeholder 建议：「例如：我先把 12 拆成 4×3，所以根号 12 可以化成 2 根号 3……」
- 多行输入，最小 2 行，最多 4-5 行。
- 不要占据手写板主体空间太多。
- 提交后不要清空，除非学生点击「下一题 / 重新开始」。
- 错误重试时必须保留输入内容。

### 5.2 步骤文字输入

保留现有手写板的 `stepId` / bounding box 机制。本轮只需要一种简单实现：

- 在手写板下方或侧边展示当前自动切分出的步骤列表。
- 每个步骤显示 `step_1`、`step_2` 等 ID。
- 每个步骤旁边有一个小输入框：
  - `plainText`：学生用中文或普通数学表达写这一行内容。
  - 可选 `latex`：高级输入，允许填 `\sqrt{12}=2\sqrt{3}`。
- 如果实现步骤列表成本太高，可以先只提供一个「本轮步骤说明」大输入框，并把内容写入第一步 `plainText`。但文档/代码注释要说明这是临时占位。

### 5.3 提交状态

- 点击提交时，按钮仍显示 loading。
- 如果讲解文字为空也允许提交，因为学生可能只手写。
- 如果画板为空仍保持现有拦截：先写一两行再提交。
- 请求失败时，手写内容、讲解文字、步骤文字都不得清空。

## 6. 数据契约

继续复用第三轮请求体，不新增必需字段：

```json
{
  "sectionId": "pep-g8-down-s16-3",
  "questionId": "mock-radical-001",
  "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}",
  "studentSpeechText": "我先把根号十二化成二根号三，再把根号二十七化成三根号三，最后相减。",
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

约束：

- 不改 `LectureSubmitResponse`。
- 不改 `AgentTurn` 字段。
- 不新增前端必须依赖的后端响应字段。
- `studentSpeechText`、`plainText`、`latex` 可以为空字符串，但不能缺字段导致解析失败。

## 7. 后端要求

第三轮 `lecture_agent.py` 已经把 `studentSpeechText`、`plainText`、`latex` 拼进 Prompt；本轮只需确认并轻微优化：

- Prompt 要明确要求模型优先根据学生口述和步骤文字追问，而不是只根据题面泛泛追问。
- 如果 `studentSpeechText` 和所有步骤文字都为空，允许走原有逻辑。
- 不要把学生输入原样当作正确答案；要让 Agent 检查其中可能的前提条件、化简规则和计算错误。
- 保持 JSON 解析校验与 fallback 逻辑不变。

## 8. UI 风格要求

- 遵守 `MOBILE_STYLE.md` 的平板优先双栏布局。
- 输入框必须是温和纸张/卡片风格，不要变成密集表单后台。
- 触控区不小于 `48dp`。
- 输入区文案要像学习 App，不要像调试面板。
- 不展示字段名 `studentSpeechText`、`plainText`、`latex` 给学生。

## 9. 验收标准

本轮完成后必须满足：

- 讲题页可以输入一段“我刚才是这样讲的”。
- 至少能把一段步骤说明传入 `steps[].plainText`。
- 点击提交后，请求体中包含非空 `studentSpeechText` 或 `plainText`。
- 后端 LLM 追问明显引用学生输入内容，例如指出某一步“为什么可以拆成 4×3”或“同类二次根式为什么能相减”。
- 请求失败或重试时，手写、讲解文字、步骤说明不丢失。
- 不破坏第三轮真实 LLM 与 fallback。
- 不破坏首页目录、章节置灰、手写板撤销/清空/高亮。

## 10. 建议测试

后端：

```bash
cd main
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

用 curl 验证语义字段会进入 LLM/fallback 路径：

```bash
curl -X POST http://127.0.0.1:8001/lecture/submit \
  -H 'Content-Type: application/json' \
  -d '{"sectionId":"pep-g8-down-s16-3","questionId":"mock-radical-001","questionPrompt":"化简：\\sqrt{12}-\\sqrt{27}","studentSpeechText":"我先把根号十二变成二根号三，再把根号二十七变成三根号三，最后得到负一根号三。","steps":[{"stepId":"step_1","latex":"\\sqrt{12}=2\\sqrt{3}","plainText":"根号12化成2根号3","strokeCount":3,"boundingBox":{"x":120,"y":80,"width":360,"height":96}},{"stepId":"step_2","latex":"\\sqrt{27}=3\\sqrt{3}","plainText":"根号27化成3根号3","strokeCount":3,"boundingBox":{"x":120,"y":190,"width":360,"height":96}}]}'
```

前端：

```bash
cd main/mobile
flutter analyze
flutter run
```

如果无法真机运行，至少通过日志或后端打印确认请求体包含新增语义字段。

## 11. 完成后同步

- 更新 `README.md`：说明讲题页已支持手动讲解文字 / 步骤文字输入。
- 更新 `DEMO_SCRIPT.md`：追加“学生语义输入驱动 AI 追问”的演示条目。
- 若踩到 Flutter 输入框、键盘遮挡、请求字段、Prompt 使用学生输入的问题，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
