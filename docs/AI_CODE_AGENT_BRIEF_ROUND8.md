# AI Code Agent 执行指令：第八轮本地讲题回顾与错因卡片闭环

> 本页用于约束 AI Code Agent 的第八轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND3.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND4.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND5.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND6.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND7.md`，并以本页作为本次任务边界。

## 1. 当前进度判断

前七轮已经完成：

- 学生端课程目录、讲题页、手写板、多 Agent 追问。
- 真实 LLM 结构化追问与 fallback。
- 学生语义输入与多轮上下文。
- 本地掌握度、完成次数、首页进度展示。
- V1 二次根式每节 3 道本地题，并支持难度标签、知识标签、下一题轮换。

当前主要短板：完成过的讲题只留下小节级 `lastSummary`，学生无法回看“我刚才完成的是哪道题、AI 追问过什么、我下次要注意什么”。后续家长端的“精彩回放 / 弱项看板”也需要先有本地回顾数据形状。

## 2. 本轮目标

做出本地讲题回顾闭环：

**完成一题 → 保存一条本地讲题回顾记录 → 首页/讲题页可进入回顾列表 → 回看题目、总结、AI 追问与待注意点 → 可一键再讲这题。**

本轮仍只做本地持久化，不做后端数据库、不做视频回放、不做家长端。

## 3. 严格范围

本轮只做以下事情：

- 完成题目时保存一条 `LectureReviewRecord`。
- 本地按时间倒序保存最近若干条回顾记录。
- 首页可练习小节显示“回顾”入口或最近回顾提示。
- 新增一个轻量回顾页，展示当前小节的最近讲题记录。
- 回顾记录展示：
  - 题目
  - 难度 / 标签
  - 完成时间
  - 本题总结
  - AI 追问摘要
  - 待注意点
- 回顾页支持「再讲这题」：回到讲题页并定位到对应 `questionId`。
- 不破坏第七轮题目轮换、第六轮掌握度、第五轮多轮上下文。

## 4. 本轮不做

以下能力继续禁止展开：

- 不做后端数据库。
- 不做账号同步。
- 不做视频/音频回放。
- 不保存手写笔迹点集。
- 不做完整聊天记录检索。
- 不做家长端。
- 不做错题本复杂分类。
- 不做 LLM 二次总结接口。
- 不做题级掌握度算法。

## 5. 数据设计

建议新增模型：

```dart
class LectureReviewRecord {
  final String id;
  final String sectionId;
  final String questionId;
  final String questionPrompt;
  final int difficulty;
  final List<String> tags;
  final DateTime completedAt;
  final String summary;
  final List<String> agentHighlights;
  final List<String> cautionPoints;
}
```

字段说明：

- `id`：本地唯一 ID，可用 `'$questionId-${DateTime.now().millisecondsSinceEpoch}'`。
- `summary`：沿用第六轮 completed 时生成的本题总结。
- `agentHighlights`：从本题最后几条 AI turn 中提取 1-3 条短文本。
- `cautionPoints`：本轮不要再调 LLM，优先用本地规则生成。

## 6. 错因 / 待注意点规则

本轮不新增 LLM 调用，使用轻量规则从题目标签、summary、AI 追问中生成待注意点。

建议规则：

- 标签含 `非负条件` / `取值范围`：加入「写二次根式前先检查被开方数是否非负」。
- 标签含 `前提条件`：加入「使用乘除法则时要补充 $a,b$ 的取值前提」。
- 标签含 `同类二次根式` / `合并同类项`：加入「先化成最简二次根式，再合并同类项系数」。
- 标签含 `负号`：加入「合并系数时留意减号和括号」。
- 如果没有命中规则，加入兜底：「回看高亮步骤，确认每一步为什么成立」。

每条记录最多展示 3 个待注意点。

## 7. 本地持久化

可以复用 `shared_preferences`，不新增数据库依赖。

建议新增文件：

- `main/mobile/lib/data/review_models.dart`
- `main/mobile/lib/services/review_repository.dart`
- `main/mobile/lib/pages/review_page.dart`

存储 key：

```text
ai_feynman.lecture_reviews.v1
```

存储结构建议：

```json
[
  {
    "id": "q-s16-3-002-1770000000000",
    "sectionId": "pep-g8-down-s16-3",
    "questionId": "q-s16-3-002",
    "questionPrompt": "化简：$2\\sqrt{8} + \\sqrt{18}$。",
    "difficulty": 2,
    "tags": ["化简", "合并同类项"],
    "completedAt": "2026-05-22T00:30:00.000",
    "summary": "这次你说清楚了先化简再合并同类二次根式。",
    "agentHighlights": ["小明追问了为什么要先把 \\sqrt{8} 化成 2\\sqrt{2}。"],
    "cautionPoints": ["先化成最简二次根式，再合并同类项系数"]
  }
]
```

容量控制：

- 全局最多保留最近 30 条。
- 单小节回顾页只展示该小节最近 10 条。
- 写入失败只打 log，不影响 completed 体验。

## 8. 保存时机

在讲题页收到 `status: "completed"` 且第六轮 progress 更新成功或完成后，保存回顾记录。

要求：

- 每次 completed 只保存 1 条，不因 setState 重建重复保存。
- 「再讲一遍」再次 completed 可以保存新记录。
- 「下一题」不应删除已有回顾。
- 如果保存 review 失败，掌握度仍应正常更新。

## 9. 回顾页 UI

新增回顾页，建议入口：

- 首页每个已开放小节的 pill / 卡片上增加一个小入口「回顾」。
- 或在小节已完成后显示「查看回顾」按钮。

回顾页内容：

- 标题：`16.3 二次根式的加减 · 讲题回顾`
- 空状态：`完成一题后，这里会出现你的讲题小结和 AI 追问。`
- 记录卡片：
  - 题目 + 难度 chip + 标签 chip
  - 完成时间
  - 本题总结
  - AI 追问摘要
  - 待注意点
  - 按钮：`再讲这题`

UI 要求：

- 遵守 `MOBILE_STYLE.md`。
- 卡片清爽，不要做成密集日志列表。
- 数学公式仍用 `FormulaText` 渲染。
- 触控区 `>= 48dp`。

## 10. 再讲这题

回顾页点击「再讲这题」：

- 跳转到 `LecturePage`。
- `LecturePage` 支持可选初始 `questionId` 或 `initialQuestionIndex`。
- 若找到对应题目，定位到该题。
- 若找不到，回到该小节第 1 题。
- 进入后画板、输入区、history 都是全新状态。
- 不清空本地 progress / review。

## 11. 验收标准

本轮完成后必须满足：

- 完成一题后，本地保存一条 review record。
- 首页已开放小节能进入回顾页。
- 回顾页能看到该小节最近完成的题目。
- 回顾卡片显示题目、难度、标签、总结、AI 摘要、待注意点。
- 点击「再讲这题」能进入对应题目，而不是默认第 1 题。
- App 重启后回顾记录仍存在。
- 最多保留最近 30 条，旧记录不会无限增长。
- 第七轮下一题轮换、第六轮进度累计不被破坏。

## 12. 建议测试

前端：

```bash
cd main/mobile
flutter analyze
flutter run
```

手动验证：

1. 进入 16.3 第 2 题并完成一轮。
2. 返回首页，点击 16.3 的「回顾」入口。
3. 确认回顾页出现刚完成的题目。
4. 点击「再讲这题」，确认进入 16.3 第 2 题。
5. 重启 App，确认回顾记录仍存在。
6. 连续完成多题，确认回顾按时间倒序展示。

如果无法真机运行，至少验证 `ReviewRepository` 的 encode/decode 和容量裁剪逻辑。

## 13. 完成后同步

- 更新 `README.md`：说明学生端已有本地讲题回顾页。
- 更新 `DEMO_SCRIPT.md`：追加“完成一题后进入讲题回顾并再讲这题”的演示条目。
- 若新增本地存储 key，确认文档写清楚。
- 若踩到重复保存、回顾页公式渲染、再讲这题定位、容量裁剪问题，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有无关修改。
