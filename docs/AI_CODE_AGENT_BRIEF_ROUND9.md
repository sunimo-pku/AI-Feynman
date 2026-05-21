# AI Code Agent 执行指令：第九轮学生端实时闭环总收口

> 本页用于约束 AI Code Agent 的第九轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND3.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND4.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND5.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND6.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND7.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND8.md`，并以本页作为本次任务边界。

## 0. 强制产品方向

本轮不是“小修小补”，而是 **学生端 MVP 总收口**。

除家长端之外，本轮要把学生端核心体验一次性打通：

**实时双工音频 + 白板书写 + 实时/准实时 ASR + 白板步骤语义 + 多 Agent 流式追问 + 白板高亮 + TTS 播放 + 学生打断 AI + 本地进度/回顾沉淀。**

硬性原则：

- 主输入是 **音频讲解 + 白板书写**，不是打字。
- ASR 文本只作为内部语义数据传给 LLM，默认不展示完整转写文本。
- 白板步骤语义应来自白板识别或白板结构化事件，不要求学生手动补文字。
- 必须保证实时性：学生正在讲/写时，系统要持续感知；学生自然停顿后，AI 要尽快追问。
- 家长端本轮不做，其余学生端关键闭环本轮都要收口。

## 1. 当前进度判断

前八轮已经完成：

- 学生端课程目录、讲题页、白板、多 Agent 追问。
- 真实 LLM 结构化追问与 fallback。
- 本地多轮上下文、掌握度、题库轮换、讲题回顾。
- 后端已有 `/asr`、`/tts`、`/lecture/submit` 等基础能力。

当前主要短板：

- 讲题体验还不是实时双工。
- ASR 还没有进入持续会话。
- 白板步骤还没有自动语义化/OCR 化。
- 多 Agent 回复还不是流式现场讨论。
- 没有 TTS 播放与学生打断 AI。
- UI 仍有前几轮为了占位引入的文字输入痕迹，需要从主路径移除。

## 2. 本轮目标

做出学生端完整实时 MVP：

**学生点击“开始讲题” → 一边写白板一边口头讲解 → 前端持续发送音频 chunk 与白板事件 → 后端维护实时讲题会话 → ASR 持续形成语义片段 → 白板步骤被自动结构化/OCR 或占位识别 → 学生自然停顿时多 Agent 流式追问 → 前端逐步展示角色气泡、播放 TTS、同步高亮白板步骤 → 学生开口或落笔可打断 AI → 完成后写入本地掌握度与讲题回顾。**

## 3. 严格范围

本轮必须完成以下学生端能力：

- 实时讲题会话通道。
- 持续麦克风采集。
- 音频 chunk 上传。
- 白板 step snapshot / ink event 上传。
- 实时或准实时 ASR 聚合。
- 白板步骤自动语义化入口。
- 逻辑气口检测与追问触发。
- 多 Agent 流式输出。
- 前端流式角色气泡渲染。
- 白板 `highlightStepIds` 高亮。
- TTS 播放角色发言。
- 学生声音 / 落笔打断 AI 播放。
- 出错 fallback：实时能力失败时，仍能回落到现有 `/lecture/submit` 非流式闭环。
- 完成题目后继续复用第六/八轮本地进度与回顾。

## 4. 本轮不做

以下能力本轮仍不做：

- 家长端。
- 账号级云同步。
- 后端数据库持久化学习历史。
- 真实视频回放。
- 排行榜、晶石、地理定位。
- 商业级完美 OCR 精度。
- 商业级 200ms ASR 全链路保证。

但注意：虽然不要求商业级极限性能，**架构和体验必须是实时双工形态**，不能再退回“录完一段再提交”的离线表单。

## 5. 实时性硬指标

本轮验收必须以实时性为核心。

目标指标：

- 麦克风开始后，前端每 `250ms - 500ms` 形成音频 chunk。
- 白板新增/更新 step 后，`500ms` 内发送最新 snapshot。
- ASR 片段从音频窗口完成到后端产出文本，目标 `1s - 3s`。
- 学生自然静音 `1.5s` 后，触发多 Agent 思考。
- 多 Agent 首个角色气泡应在触发后 `3s - 8s` 内出现；LLM 慢时要有明确“AI 正在想问题”状态。
- 流式追问开始后，前端应逐步显示，而不是等整段结束才出现。
- 学生开口或落笔打断 AI 时，TTS 应在 `200ms - 500ms` 内停止或淡出。

如某项因三方 ASR/LLM 延迟达不到，必须有降级机制和状态提示，但不能阻塞白板与会话继续。

## 6. 后端实时接口

新增 WebSocket：

```text
WS /lecture/live
```

建议新增文件：

- `main/app/routers/lecture_live.py`
- `main/app/services/live_lecture_session.py`
- `main/app/services/live_asr_buffer.py`

### 6.1 前端发送事件

开始会话：

```json
{
  "type": "session_start",
  "sessionId": "local-session-xxx",
  "sectionId": "pep-g8-down-s16-3",
  "questionId": "q-s16-3-001",
  "questionPrompt": "化简：\\sqrt{12}-\\sqrt{27}"
}
```

音频 chunk：

```json
{
  "type": "audio_chunk",
  "sessionId": "local-session-xxx",
  "seq": 12,
  "format": "pcm16",
  "sampleRate": 16000,
  "base64": "<audio bytes>"
}
```

白板步骤：

```json
{
  "type": "ink_snapshot",
  "sessionId": "local-session-xxx",
  "steps": [
    {
      "stepId": "step_1",
      "strokeCount": 4,
      "boundingBox": {"x": 120, "y": 80, "width": 360, "height": 96},
      "latex": "",
      "plainText": ""
    }
  ]
}
```

自然停顿：

```json
{
  "type": "pause_detected",
  "sessionId": "local-session-xxx",
  "silenceMs": 1600
}
```

学生打断：

```json
{
  "type": "student_interrupt",
  "sessionId": "local-session-xxx",
  "reason": "voice"
}
```

结束会话：

```json
{
  "type": "session_end",
  "sessionId": "local-session-xxx"
}
```

### 6.2 后端返回事件

状态：

```json
{"type": "listening", "sessionId": "local-session-xxx"}
```

ASR 片段：

```json
{
  "type": "asr_segment",
  "sessionId": "local-session-xxx",
  "text": "我先把根号十二化成二根号三"
}
```

AI 思考：

```json
{
  "type": "thinking",
  "sessionId": "local-session-xxx"
}
```

角色发言开始：

```json
{
  "type": "agent_turn_start",
  "sessionId": "local-session-xxx",
  "turnId": "turn_1",
  "role": "xiaoming",
  "displayName": "小明",
  "highlightStepIds": ["step_1"]
}
```

角色发言增量：

```json
{
  "type": "agent_turn_delta",
  "sessionId": "local-session-xxx",
  "turnId": "turn_1",
  "delta": "你刚才说..."
}
```

角色发言结束：

```json
{
  "type": "agent_turn_done",
  "sessionId": "local-session-xxx",
  "turnId": "turn_1"
}
```

整轮完成：

```json
{
  "type": "round_done",
  "sessionId": "local-session-xxx",
  "status": "needs_explanation",
  "masteryDelta": 0
}
```

## 7. 后端实现要求

后端 live session 需要维护：

- `sessionId`
- `sectionId`
- `questionId`
- `questionPrompt`
- `audioBuffer`
- `transcriptSegments`
- `latestInkSnapshot`
- `history`
- `isThinking`
- `lastActivityAt`

ASR 策略：

- 第一版可把音频 chunk 聚合成 `2s - 4s` 小窗口。
- 每个窗口调用现有火山 ASR。
- ASR 结果追加到 `transcriptSegments`。
- ASR 失败不终止 session，只发 warning 状态。

LLM 策略：

- 收到 `pause_detected` 且 `isThinking == false` 时，构造现有 `LectureSubmitRequest` 等价数据。
- `studentSpeechText` 使用最近若干个 ASR segment 拼接。
- `steps` 使用最新白板 snapshot。
- `history` 使用当前 session 历史。
- 复用现有 lecture agent。
- 若现有 lecture agent 暂不支持真正 token 流，可先在后端拿到完整 turns 后拆成短 delta 逐步发给前端；但前端必须以流式事件形态消费。

Fallback：

- LLM / ASR 失败时，仍使用已有 fallback 追问。
- WebSocket 断开时，前端白板不丢，可重新开始 session。

## 8. Flutter 前端架构

建议新增：

- `main/mobile/lib/services/audio_stream_service.dart`
- `main/mobile/lib/services/live_lecture_service.dart`
- `main/mobile/lib/data/live_lecture_events.dart`
- `main/mobile/lib/widgets/realtime_audio_panel.dart`

职责：

- `AudioStreamService`：麦克风权限、开始/暂停/停止、音频 chunk 流、音量估计。
- `LiveLectureService`：WebSocket 连接、事件发送、事件解析、重连/断开。
- `LiveLectureEvents`：所有 live event 的 Dart 模型。
- `RealtimeAudioPanel`：开始讲题、暂停倾听、结束本题、状态展示。

依赖建议：

```bash
cd main/mobile
flutter pub add record permission_handler web_socket_channel
```

如录音库需要临时文件，可再加 `path_provider`。

## 9. Flutter UI 要求

讲题页主交互改成：

- 右侧：白板仍占主面积。
- 白板下方/侧边：实时音频控制面板。
- 左侧：多 Agent 讨论区，支持流式气泡。

音频面板状态：

- `开始讲题`
- `正在听你讲...`
- `检测到停顿，AI 正在想问题...`
- `AI 同伴正在说话`
- `你打断了 AI，我继续听你讲`
- `连接断开，白板还在，可以重新开始`

禁止：

- 默认展示完整 ASR 转写文本。
- 默认展示文字输入框。
- 要求学生手动修正文字。
- 把“提交讲解”作为唯一动作。

允许：

- Debug 模式下隐藏查看 transcript。
- 白板-only 兜底提交。

## 10. 白板语义 / OCR 入口

本轮必须为白板语义留入口，不能继续依赖学生手动打字。

最小实现：

- 前端继续发送 stepId、strokeCount、boundingBox。
- 可在后端将 `plainText/latex` 留空，但 prompt 中要明确“白板当前有这些步骤坐标和笔画数”。
- 若已有能力可做截图或轨迹转图片，则新增 `/ocr/ink` 占位接口或 service stub。
- OCR 未完成时不要让 UI 暴露“请手动输入这一步文字”为主路径。

验收时允许 OCR 仍是占位，但代码结构必须清楚显示：未来白板语义来自 OCR / ink parser。

## 11. TTS 与打断

本轮要做最小 TTS 播放和打断，不再拖后。

要求：

- 角色 turn 完成或有足够文本时，请求现有 `/tts`。
- 前端播放 TTS。
- 学生开始说话或落笔时，立即停止/淡出当前播放。
- 打断后 UI 显示“我继续听你讲”。

可接受降级：

- 第一版可以等 `agent_turn_done` 后再 TTS，不要求边生成边播。
- 淡出可以先用快速停止替代，但代码/文档要标 TODO：200ms fade-out。

不可接受：

- AI 说话时学生无法打断。
- TTS 播放阻塞白板书写。

## 12. 逻辑气口策略

本轮必须实现最小气口策略：

- 学生持续说话时，不触发 AI 追问。
- 学生静音 `>= 1.5s` 且当前没有新笔画，可触发追问。
- 学生静音但仍在写，暂不追问。
- 学生点击“我讲到这里”可手动触发追问。
- 同一轮追问生成中忽略重复触发。

## 13. 权限与错误处理

必须处理：

- 麦克风权限拒绝。
- 录音开始失败。
- WebSocket 连接失败。
- WebSocket 中途断开。
- ASR 窗口失败。
- LLM 超时。
- TTS 失败。
- `VOLC_API_KEY` 未配置。

错误时：

- 白板不清空。
- 本地 history 不乱写。
- 可重新开始实时会话。
- 可回落到已有非实时 `/lecture/submit` 闭环。

## 14. 验收标准

本轮完成后必须满足：

- 进入讲题页后可以点击“开始讲题”。
- 麦克风持续采集并发送 chunk。
- 白板 step snapshot 进入同一 live session。
- 学生边写边讲时，系统保持 listening，不抢话。
- 学生自然停顿后，AI 进入 thinking。
- 前端以流式气泡展示多 Agent 追问。
- 追问能高亮对应白板 step。
- AI 追问可通过 TTS 播放。
- 学生开口或落笔能打断 TTS。
- 不展示完整 ASR 转写文本。
- 完成题目后仍写入本地进度和回顾。
- WebSocket/ASR/LLM/TTS 任一失败时，白板不丢，并能降级继续。
- 不破坏第八轮回顾、第七轮题库、第六轮进度。

## 15. 建议测试

后端：

```bash
cd main
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload
```

前端：

```bash
cd main/mobile
flutter pub get
flutter analyze
flutter run
```

手动验证：

1. 进入 16.3 任一题。
2. 点击“开始讲题”。
3. 一边写白板一边口头讲 5-10 秒。
4. 停顿 1.5 秒。
5. 确认 AI thinking 状态出现。
6. 确认多 Agent 气泡流式出现。
7. 确认白板对应步骤高亮。
8. 确认 TTS 播放。
9. 在 TTS 播放时开口或落笔，确认 AI 停止播放并回到 listening。
10. 断开后端，确认白板不丢，可重新开始。

如果真机录音环境暂不可用，至少完成：

- WebSocket live session 事件模拟测试。
- 前端 live event parser 测试。
- 权限拒绝分支 UI 验证。

## 16. 完成后同步

- 更新 `README.md`：说明学生端已进入实时双工讲题 MVP。
- 更新 `DEMO_SCRIPT.md`：追加“边写边讲 → 自然停顿 → 流式追问 → TTS → 学生打断”的演示条目。
- 如新增依赖，提交 `pubspec.yaml` 与 `pubspec.lock`。
- 若踩到 Android 麦克风权限、WebSocket、音频 chunk、ASR 窗口、TTS 播放、打断、防重复追问等问题，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
