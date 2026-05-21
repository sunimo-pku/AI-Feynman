# AI Code Agent 执行指令：首个可演示小闭环

> 历史说明：本页只约束第一轮最小闭环实现，保留作过程记录。当前产品边界已经升级为「全册 90 节均有题可练，所有章节同等进入多 Agent 追问闭环」；新的实现口径以 `AGENTS.md`、`README.md`、`DEMO_SCRIPT.md` 与 Round 12 文档为准。
>
> 本页用于约束 AI Code Agent 的第一轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`docs/MOBILE_STYLE.md`，并以本页作为本次任务边界。

## 1. 本次目标

做出一个能在 Android 平板上演示的最小闭环：

**课程首页 → 进入「第十六章 二次根式」讲题页 → 学生在手写板写步骤 → 点击提交 → 看到 Mock 多 Agent 追问 → 学生点击“我懂了/下一题”完成一轮。**

这个闭环优先证明产品体验，不追求真实 AI 能力全量接入。

## 2. 严格范围

本次只实现学生端 MVP 骨架：

- 课程首页读取 `data/curriculum/pep-junior-math.json`，完整展示初中数学目录。
- 第一轮当时只要求 `pep-g8-down-ch16` 下的 16.1 / 16.2 / 16.3 可进入练习。
- 第一轮当时未上线章节置灰，显示「即将上线」；当前实现已升级为全册 90 节均可练。
- 新增讲题页，平板横屏优先采用左右双栏：左侧多 Agent 对话区，右侧手写板。
- 手写板支持书写、撤销、清空、提交。
- 提交后先使用本地 Mock 数据生成 1-2 条角色追问，不接真实 LLM 也可以。
- 多 Agent 至少包含「小明」和「李老师」两个角色，语气遵循 `项目规划/planV1.md` 的人设。
- 追问内容必须围绕二次根式，例如被开方数、最简二次根式、同类二次根式、`\sqrt{a^2}=|a|`。

## 3. 本次不做

以下能力本轮不要展开，避免首个闭环失控：

- 不做真实 ASR 长连接。
- 不做真实 TTS 播放。
- 不做真实 OCR 或数学公式识别。
- 不做真实 LLM SSE 流式生成。
- 不做家长端。
- 不做排行榜、晶石、实物兑换、地理定位。
- 不做账号体系之外的新鉴权设计。
- 不做复杂掌握度算法，只允许本地展示一个占位状态，例如「理解中」或「已完成 1 轮」。

## 4. 页面要求

### 4.1 首页

- 使用 `MOBILE_STYLE.md` 的亮色自习室风格。
- 第一轮当时顶部说明「八年级下册 · 第十六章 二次根式」为唯一开放章节；当前首页口径为全册可练、所有章节同等可追问。
- 可练习章节使用知性蓝/湖青强调。
- 即将上线章节使用中灰、低透明度、锁定或标签表达，不要让用户误以为可点。

### 4.2 讲题页

- 平板横屏：左侧约 40% 为多 Agent 对话区，右侧约 60% 为手写板。
- 手机竖屏：可以降级为上下布局，不要求一次做到极致。
- 右侧手写板必须包裹 `RepaintBoundary`，避免对话刷新影响书写。
- 手写板工具至少包含「撤销」「清空」「提交讲解」。
- 初始题目可以写死为二次根式样例，例如：化简 `\sqrt{12}-\sqrt{27}`。
- 提交后左侧出现角色追问气泡，并可高亮显示“追问关联当前步骤”的占位效果。

## 5. Mock 数据约定

先在 Flutter 本地写固定 Mock，后续再替换为后端 API：

```json
{
  "questionId": "mock-radical-001",
  "sectionId": "pep-g8-down-ch16-sec1",
  "prompt": "化简：\\sqrt{12}-\\sqrt{27}",
  "turns": [
    {
      "role": "xiaoming",
      "displayName": "小明",
      "text": "我有点疑惑，\\sqrt{12} 为什么可以变成 2\\sqrt{3}？这里用了什么规律？",
      "highlightStepIds": ["step_1"]
    },
    {
      "role": "teacher",
      "displayName": "李老师",
      "text": "这个问题很好。你可以试着把 12 拆成 4×3，再说明为什么 4 能从根号里出来。",
      "highlightStepIds": ["step_1"]
    }
  ]
}
```

## 6. 建议文件结构

优先沿用 `MOBILE_STYLE.md` 中约定的目录：

- `main/mobile/lib/pages/home_page.dart`
- `main/mobile/lib/pages/lecture_page.dart`
- `main/mobile/lib/widgets/hand_canvas.dart`
- `main/mobile/lib/widgets/agent_message_bubble.dart`
- `main/mobile/lib/data/mock_lecture_repository.dart`
- `main/mobile/lib/theme/app_theme.dart`

如果现有工程已有同等职责文件，优先复用，不要重复造一套。

## 7. 验收标准

本轮完成后必须满足：

- Android/Flutter 工程可以启动到首页。
- 首页能展示完整课程目录。
- 点击二次根式可练习章节能进入讲题页。
- 点击其他章节不会进入练习，并显示「即将上线」提示。
- 讲题页能书写、撤销、清空。
- 点击「提交讲解」后出现至少 2 条 Mock 多 Agent 对话。
- UI 不出现默认紫蓝渐变 Hero、密集文字墙、过小按钮。
- 新增页面和组件符合 `MOBILE_STYLE.md` 的主色、圆角、间距、触控尺寸要求。

## 8. 完成后同步

- 若新增可演示能力，更新 `DEMO_SCRIPT.md`。
- 若新增目录或运行方式，更新 `README.md`。
- 若踩到 Flutter、SSE、语音、部署或数据坑，更新 `AGENTS.md` 的「踩坑记录」。
- 提交时只提交本次实际改动的文件，不要带入工作区已有的无关修改。
