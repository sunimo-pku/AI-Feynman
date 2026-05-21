# AI Code Agent 执行指令：第十轮全功能最终总收口

> 本页用于约束 AI Code Agent 的第十轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md` 至 `docs/AI_CODE_AGENT_BRIEF_ROUND9.md`，并以本页作为最终任务边界。

## 0. 本轮定位

本轮不再继续拆分。目标是把 **AI 费曼 V1 Demo / MVP 所有剩余功能一次性收口**。

第九轮已经完成学生端实时闭环主体。本轮补齐剩余所有产品面：

**家长端 + 后端持久化 + 鉴权接入 + 真实 OCR/白板语义 + 真流式 LLM + TTS 淡出 + 学习数据闭环 + 部署/验收/文档总收口。**

完成后，项目应达到：

- 学生端可真实演示完整「边写边讲 → 多 Agent 追问 → 掌握度更新 → 回顾」闭环。
- 家长端可查看弱项、最近讲题、回顾摘要与学习海报。
- 后端可保存学习会话与进度，不再只依赖本地 `shared_preferences`。
- Demo 路径稳定，可在 Android 平板 + 后端服务上完整跑通。

## 1. 当前进度判断

已完成：

- 课程目录与 V1 二次根式章节。
- Flutter 学生端首页、讲题页、白板。
- 本地 16.1 / 16.2 / 16.3 小题库。
- 多 Agent 追问、真实 LLM、fallback。
- 学生端实时双工 MVP：WebSocket live session、音频 chunk、白板 snapshot、逻辑气口、流式气泡、TTS、打断。
- 本地掌握度、讲题回顾、错因卡片。

仍需完成：

- 家长端。
- 后端学习数据持久化。
- 鉴权贯通学生端/家长端关键接口。
- 白板真实 OCR / ink parser。
- 真正 token 级 LLM 流式，而不是后端整段切片模拟。
- TTS 200ms 淡出。
- 数据隐私与权限提示。
- 部署、测试、Demo 文档总验收。

## 2. 严格范围

本轮必须完成以下能力：

- 家长端最小可用页面。
- 后端学习记录 / 进度 / 回顾持久化。
- 学生端本地数据与后端数据同步。
- 登录后数据隔离。
- 家长端读取孩子学习数据。
- 弱项看板。
- 最近讲题回顾。
- 总结海报。
- 白板 OCR / ink parser 最小可用。
- 真 LLM SSE / WebSocket token 流。
- TTS 200ms fade-out。
- 实时链路错误兜底。
- 全链路测试与部署文档。

本轮完成后，除商业化增强和大规模线上运营外，不应再有核心 V1 功能缺口。

## 3. 本轮不做

以下仍不做：

- 真实支付。
- 商城 / 实物兑换下单。
- 地理定位排行榜真实上线。
- 多孩子家庭复杂权限。
- 视频级白板回放文件存储。
- 大规模数据分析平台。
- 商业级 OCR 准确率保证。

但 UI 上可以保留这些能力的“即将上线”入口或灰态，不要让用户误以为已可用。

## 4. 后端数据持久化

当前 `db.py` 只有 `User` 与旧 `ChatSession`。本轮需要新增学习相关表。

建议新增表：

### 4.1 StudentProfile

字段：

- `id`
- `user_id`
- `display_name`
- `grade`
- `created_at`
- `updated_at`

### 4.2 LearningProgress

字段：

- `id`
- `student_id`
- `section_id`
- `completed_rounds`
- `mastery_score`
- `last_practiced_at`
- `last_summary`
- `updated_at`

### 4.3 LectureReview

字段：

- `id`
- `student_id`
- `section_id`
- `question_id`
- `question_prompt`
- `difficulty`
- `tags_json`
- `summary`
- `agent_highlights_json`
- `caution_points_json`
- `created_at`

### 4.4 LectureSessionRecord

字段：

- `id`
- `student_id`
- `section_id`
- `question_id`
- `question_prompt`
- `status`
- `transcript_text`
- `steps_json`
- `turns_json`
- `started_at`
- `completed_at`

注意：

- 不要复用旧 `ChatSession`，讲题闭环需要独立业务表。
- SQLite `create_all()` 不会给老表加列；新增字段时要写轻量迁移或文档说明重建库。更推荐写显式迁移函数。
- 不要保存原始音频文件，本轮只保存转写文本和结构化摘要。

## 5. 后端 API

新增路由建议：

- `GET /learning/progress`
- `POST /learning/progress/sync`
- `GET /learning/reviews`
- `POST /learning/reviews`
- `GET /parent/dashboard`
- `GET /parent/reviews`
- `GET /parent/poster`

### 5.1 同步接口

学生端本地已有 `SectionProgress` 与 `LectureReviewRecord`，本轮要支持上传同步。

`POST /learning/progress/sync` 请求：

```json
{
  "progress": [
    {
      "sectionId": "pep-g8-down-s16-3",
      "completedRounds": 3,
      "masteryScore": 42,
      "lastPracticedAt": "2026-05-22T01:00:00",
      "lastSummary": "..."
    }
  ],
  "reviews": []
}
```

策略：

- 同 section 以较高 `completedRounds` / 较新 `lastPracticedAt` 为准。
- reviews 按 `id` 去重。
- 未登录时学生端继续本地可用；登录后再同步。

### 5.2 家长 dashboard

`GET /parent/dashboard` 返回：

```json
{
  "studentName": "小明",
  "overallMastery": 46,
  "weakSections": [
    {
      "sectionId": "pep-g8-down-s16-2",
      "label": "16.2 二次根式的乘除",
      "masteryScore": 24,
      "reason": "乘除法则前提条件不稳定"
    }
  ],
  "recentReviews": [],
  "suggestedNextAction": "建议今天先复讲 16.2 的乘除法则前提。"
}
```

## 6. 鉴权与用户角色

当前后端已有 auth 中间件与用户表，但 `/lecture/submit`、`/lecture/live` 为演示豁免。

本轮要求：

- 学生端支持登录/注册最小流程，或复用已有 auth 页面/API。
- 学习数据 API 必须带 `Authorization: Bearer <token>`。
- `/lecture/submit`、`/lecture/live` 可以继续允许 demo 匿名模式，但如果带 token，应写入对应 student。
- 家长端必须登录。
- V1 可先采用同一个账号查看孩子数据，不做复杂 parent-child 绑定。

安全要求：

- 不提交 `.env`。
- 不把 API key 打到前端日志。
- 401/422 不能被通用 Exception handler 吞掉。

## 7. 家长端最小页面

可以在 Flutter App 内新增“家长端”入口，不另开 Web 前端。

建议新增：

- `main/mobile/lib/pages/parent_dashboard_page.dart`
- `main/mobile/lib/services/parent_service.dart`
- `main/mobile/lib/data/parent_models.dart`

入口：

- 首页 AppBar 增加「家长端」入口。
- 或底部/侧边切换「学生 / 家长」。

页面内容：

- 学生名称与总体掌握度。
- 弱项看板。
- 最近讲题回顾。
- 本周学习摘要。
- 一键生成总结海报。

UI 要求：

- 温和、可信、面向家长，不要做成学生游戏面板。
- 重点突出“哪里薄弱、下一步怎么练”。
- 不要只显示分数，要显示可解释原因。

## 8. 总结海报

本轮做 Flutter 本地海报卡片，不要求导出图片到相册。

海报内容：

- 学生名。
- 本周完成轮数。
- 掌握度最高章节。
- 最需要巩固章节。
- 一条老师建议。
- 最近一次精彩讲题摘要。

要求：

- 可在页面内预览。
- 可截图分享由系统能力完成，不强制实现保存图片。
- 不出现虚假排名 / 虚假奖项。

## 9. 白板 OCR / Ink Parser

本轮必须补白板语义入口，不再依赖学生手动文字。

最小可用方案二选一：

### 方案 A：OCR Stub + 规则识别

- 前端把 step 的 bounding box / stroke count / 可选 canvas image 发后端。
- 后端 `/ocr/ink` 返回结构：

```json
{
  "steps": [
    {
      "stepId": "step_1",
      "latex": "\\sqrt{12}=2\\sqrt{3}",
      "plainText": "根号12等于2根号3",
      "confidence": 0.72
    }
  ]
}
```

- 对 V1 9 道题可用规则/模板匹配做最小识别。

### 方案 B：前端辅助结构化

- 前端根据当前题目的 `referenceSteps` 提供不可见候选。
- 后端按 step 数与题目上下文做候选映射。
- UI 不展示“请手打这一步”。

验收重点：

- `/lecture/live` 的 prompt 中能拿到 `steps[].latex/plainText`，不是永远空。
- OCR 失败时仍可用白板坐标和音频继续追问。

## 10. 真 LLM 流式

第九轮可能是“后端拿完整 LLM turns 后切片模拟流式”。本轮要改成真正 token / delta 流。

要求：

- `lecture_agent` 或新增 `lecture_agent_stream` 支持 LLM streaming。
- 后端将模型 delta 解析为角色 turn 流。
- 如果模型输出 JSON 不适合 token 流，可改为后端 prompt 让模型输出 NDJSON event：

```json
{"type":"turn_start","role":"xiaoming","displayName":"小明","highlightStepIds":["step_1"]}
{"type":"delta","text":"你刚才说..."}
{"type":"turn_done"}
```

- 前端仍消费 `agent_turn_start/delta/done`。
- 如果 streaming 解析失败，回落到第九轮切片模拟流式。

## 11. TTS Fade-out

第九轮允许快速 stop。本轮必须实现淡出。

要求：

- 学生打断时，TTS 在 `200ms - 500ms` 内降低音量到 0 再 stop。
- 不阻塞白板书写。
- 同时向后端发送 `student_interrupt`。
- UI 显示“你打断了 AI，我继续听你讲”。

如果 `audioplayers` 实现困难，可换 `just_audio`，但要控制依赖影响。

## 12. 实时链路最终验收

最终实时链路必须满足：

- 边写边讲时系统 listening。
- 1.5s 逻辑气口后触发追问。
- 模型开始输出后前端逐字/分段增长。
- TTS 播放角色发言。
- 学生开口或落笔可以打断。
- 打断后继续 listening。
- 完成后写后端和本地进度。
- 家长端 dashboard 能看到更新。

## 13. 部署与配置

必须更新：

- `.env.example`
- `README.md`
- `docs/MAC_LOCAL_DEV.md`
- `DEMO_SCRIPT.md`
- `AGENTS.md` 踩坑记录

需要确认：

- `deploy.sh` 包含新路由不需要额外步骤。
- WebSocket 反代配置可用。
- nginx 若存在，要支持 WebSocket upgrade。
- 慢接口 timeout 足够。
- Android 真机 Base URL 不能是 localhost。

## 14. 测试要求

后端：

- `/health`
- `/lecture/live` WebSocket 事件模拟。
- `/learning/progress/sync`
- `/parent/dashboard`
- `/ocr/ink`
- auth 401/422。

前端：

- `flutter analyze`
- 真机或模拟器跑通：
  - 学生端实时讲题。
  - TTS 打断。
  - 完成后进度同步。
  - 回顾页。
  - 家长端 dashboard。

若某项无法自动化，必须在最终回复中说明未验证原因。

## 15. Demo 最终脚本

最终 Demo 必须覆盖：

1. 首页目录与 V1 边界。
2. 学生进入 16.3 第 2 题。
3. 边写边讲。
4. 自然停顿触发多 Agent 流式追问。
5. 白板高亮。
6. TTS 播放。
7. 学生开口/落笔打断。
8. 多轮回答到 completed。
9. 本地/后端进度更新。
10. 回顾页再讲这题。
11. 家长端看弱项和最近讲题。
12. 总结海报。

## 16. 完成后同步

- 更新 `README.md`：说明 V1 学生端 + 家长端完整闭环。
- 更新 `DEMO_SCRIPT.md`：追加最终完整演示脚本。
- 更新 `项目规划/planV1.md`：标注 V1 MVP 已完成的范围。
- 更新 `.env.example`：补齐所有新增配置。
- 更新 `AGENTS.md`：记录 WebSocket、ASR、OCR、TTS、SQLite 迁移、鉴权坑。
- 若新增依赖，提交对应 lock 文件。
- 提交时只提交本次实际改动文件，不要带入无关修改。

## 17. 最终验收定义

本轮结束后，如果仍有以下任一缺口，就不算完成：

- 学生端不能实时边写边讲。
- 家长端看不到弱项和最近讲题。
- 学习进度只在本地、不进后端。
- TTS 不能被学生打断。
- 白板步骤语义永远为空。
- LLM 回复只能整段返回，没有流式体感。
- 登录后数据不能隔离。
- Demo 无法按脚本完整跑通。
