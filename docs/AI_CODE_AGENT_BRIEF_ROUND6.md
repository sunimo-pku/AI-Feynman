# AI Code Agent 执行指令：第六轮本地掌握度与总结闭环

> 本页用于约束 AI Code Agent 的第六轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND3.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND4.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND5.md`，并以本页作为本次任务边界。

## 1. 当前进度判断

前五轮已经完成：

- Flutter 学生端首页与二次根式讲题页骨架。
- 手写板书写、撤销、清空、提交与步骤高亮。
- `POST /lecture/submit` 后端接口。
- 后端真实 Kimi / LLM 结构化多 Agent 追问，并保留 Mock fallback。
- 讲题页支持学生手动输入口述讲解、步骤说明和可选 LaTeX。
- 前端与后端支持 `roundIndex` / `history`，能够进行本地多轮追问。
- 后端可根据学生回答返回 `status: "completed"` 和 `masteryDelta`。

当前主要短板：题目完成后没有“学习结果沉淀”。学生讲清楚一题后，页面只进入完成态，但首页、章节、当前题都没有稳定展示“我完成了几轮、掌握度有什么变化、这题学到了什么”。

## 2. 本轮目标

做出一个本地学习结果闭环：

**AI 判定 completed → 前端生成/展示本题总结 → 本地更新该小节掌握度与完成次数 → 首页和讲题页能看到进度变化。**

本轮只做本地持久化，不接后端数据库，不做账号级学习历史。

## 3. 严格范围

本轮只做以下事情：

- 前端收到 `/lecture/submit` 返回 `status: "completed"` 后，更新本地进度。
- 本地按 `sectionId` 记录：
  - `completedRounds`
  - `masteryScore`
  - `lastPracticedAt`
  - `lastSummary`
- 讲题页完成态展示一张「本题讲题小结」卡片。
- 首页课程目录中，可练习小节显示本地掌握度 / 完成次数。
- 进度只覆盖 V1 可练习小节：16.1 / 16.2 / 16.3。
- 保持第五轮多轮追问、第四轮语义输入、第三轮 LLM fallback 不被破坏。

## 4. 本轮不做

以下能力继续禁止展开：

- 不做后端数据库持久化。
- 不做账号级跨设备同步。
- 不做家长端。
- 不做排行榜、晶石、地理定位。
- 不做复杂掌握度算法。
- 不做 ASR、OCR、TTS。
- 不做 SSE 流式输出。
- 不引入重型状态管理框架。

## 5. 数据设计

建议新增本地数据模型：

```dart
class SectionProgress {
  final String sectionId;
  final int completedRounds;
  final int masteryScore; // 0-100
  final DateTime? lastPracticedAt;
  final String lastSummary;
}
```

本轮掌握度算法保持简单：

- 初始 `masteryScore = 0`。
- 每次 `completed`：
  - `completedRounds += 1`
  - `masteryScore += max(8, masteryDelta * 10)`
  - 上限 100。
- 如果 `masteryDelta <= 0` 但 `status == completed`，仍至少加 8 分，避免学生完成一题却没有正反馈。
- 不处理倒扣，不做遗忘曲线。

## 6. 本地持久化

优先使用轻量方案：

- 若项目尚未有本地存储依赖，可添加 `shared_preferences`。
- 通过 package manager 添加依赖，例如：

```bash
cd main/mobile
flutter pub add shared_preferences
```

建议新增文件：

- `main/mobile/lib/data/progress_models.dart`
- `main/mobile/lib/services/progress_repository.dart`

存储 key 建议：

```text
ai_feynman.section_progress.v1
```

存储内容建议为 JSON map：

```json
{
  "pep-g8-down-s16-3": {
    "sectionId": "pep-g8-down-s16-3",
    "completedRounds": 2,
    "masteryScore": 26,
    "lastPracticedAt": "2026-05-21T23:30:00.000",
    "lastSummary": "能说明 \\sqrt{12}=2\\sqrt{3} 的拆分依据，但还要注意同类二次根式合并时的负号。"
  }
}
```

## 7. 本题总结

本轮不要为了总结再调用一次 LLM。优先从已有信息拼一个轻量总结：

- 如果后端返回 `completed`，使用最后一条 `teacher` turn 作为 `lastSummary`。
- 如果没有老师发言，使用最后一条 AI turn。
- 如果都没有，使用兜底文案：
  - 「本题已完成一轮讲解，建议回看高亮步骤，总结这一步为什么成立。」

讲题页完成态展示：

- 标题：「本题讲清楚了」
- 本轮小结：`lastSummary`
- 掌握度变化：例如「本节掌握度 +10，当前 36/100」
- 操作：
  - 「下一题」
  - 「再讲一遍」

## 8. 首页展示要求

在 `HomePage` 的可练习小节条目中显示本地进度：

- 未完成：`可练习`
- 已完成至少一轮：`已完成 1 轮 · 掌握度 18/100`
- 最近练习时间可以先不展示，或在二级文字中温和显示。

未上线章节仍只显示「即将上线」，不要显示进度。

首页加载时：

- 异步读取本地 progress。
- 不要因为 progress 读取失败影响课程目录展示。
- 失败时可以当作空进度。

## 9. 状态同步要求

- 讲题页完成后更新本地 progress。
- 返回首页后能看到更新后的完成次数与掌握度。
- 如果 Flutter 路由返回时首页没有自动刷新，可以在 `Navigator.push` 返回后触发重新加载 progress。
- 点击「下一题 / 重新开始」不应清空 progress，只清空当前题临时状态。
- 清空手写板不应清空 progress。

## 10. UI 风格要求

- 遵守 `MOBILE_STYLE.md`。
- 总结卡片要像学习反馈，不要像后台日志。
- 进度表达要鼓励但克制，不要游戏化过头。
- 不要用高饱和渐变和夸张动画。
- 触控区保持 `>= 48dp`。

## 11. 验收标准

本轮完成后必须满足：

- 当 `/lecture/submit` 返回 `status: "completed"`，讲题页显示「本题讲清楚了」总结卡。
- 本地 `completedRounds` 增加。
- 本地 `masteryScore` 增加且不超过 100。
- 返回首页后，对应 16.x 小节能看到完成轮数与掌握度。
- 关闭 App 再打开后，本地进度仍存在。
- 未上线章节仍不可进入，且不展示掌握度。
- 第五轮多轮追问上下文仍可用。
- 第三轮 LLM fallback 仍可用。

## 12. 建议测试

前端：

```bash
cd main/mobile
flutter pub get
flutter analyze
flutter run
```

手动验证：

1. 进入 16.3 讲题页。
2. 写一两步，输入讲解文字。
3. 提交并完成多轮追问，直到后端返回 `completed`。
4. 确认完成卡片出现。
5. 返回首页，确认 16.3 显示完成次数与掌握度。
6. 重启 App，确认进度仍存在。

如果本地无法跑真机，至少用单元级方式验证 `ProgressRepository` 的 JSON encode/decode。

## 13. 完成后同步

- 更新 `README.md`：说明学生端已有本地掌握度与完成次数展示。
- 更新 `DEMO_SCRIPT.md`：追加“完成一题后首页掌握度变化”的演示条目。
- 若新增 `shared_preferences`，确认 `pubspec.yaml` 与 `pubspec.lock` 同步提交。
- 若踩到本地存储、首页刷新、完成态重复加分等问题，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
