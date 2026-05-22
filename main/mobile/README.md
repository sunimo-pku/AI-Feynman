# Flutter Android 客户端

AI 费曼学习法 · Android App（Flutter / Dart）。

## 前置条件

- Flutter SDK（stable）
- Android Studio 或 Android SDK + 设备/模拟器

## 开发

```bash
cd main/mobile
flutter pub get
flutter run
```

### API 地址

默认 `http://10.0.2.2:8001`（Android 模拟器访问本机后端）。

真机调试：

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8001
```

或在 `lib/config/api_config.dart` 修改 `defaultValue`。

## 构建 APK

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

## 目录

```
lib/
├── main.dart
├── config/                          # API 配置
├── data/
│   ├── curriculum_models.dart       # 课程目录模型
│   ├── curriculum_repository.dart   # 加载 assets/curriculum/*.json
│   ├── lecture_models.dart          # 讲题 / 多 Agent 对话数据模型
│   ├── mock_lecture_repository.dart # 全册 90 节题库 asset + 16 章兜底题
│   └── round12_models.dart          # V2 游戏化 / 回放 / 题库模型
├── pages/
│   ├── student_main_shell.dart      # 学生主壳（底部四 Tab）
│   ├── home_dashboard_tab.dart      # 今日 Tab
│   ├── curriculum_tab_page.dart     # 课程 Tab + curriculum_book_page 二级目录
│   ├── more_tab_page.dart           # 更多 Tab
│   ├── home_page.dart               # 导出 StudentMainShell（兼容旧 import）
│   └── lecture_page.dart            # 讲题页（左右双栏，平板优先）
├── services/                        # HTTP / SSE / 语音等
├── theme/
│   └── app_theme.dart               # MOBILE_STYLE 自习室色板 + 圆角 + 间距
└── widgets/
    ├── formula_text.dart            # 行内 / 块级公式占位渲染（LaTeX → Unicode）
    ├── hand_canvas.dart             # 带 RepaintBoundary 的手写板（撤销/清空/分步/高亮）
    └── agent_message_bubble.dart    # 多 Agent 对话气泡（按角色调色）
assets/curriculum/                   # 人教版目录 JSON（与 data/curriculum 同步）
assets/questions/                    # 全册 90 节题库 JSON + SVG 题图
```

## 演示闭环

1. 首页展示「人教版 · 初中数学」完整 6 册 29 章；全册 90 节均有基础 / 巩固 / 挑战 3 题可进入练习，所有章节都进入同一套多 Agent 追问闭环。
2. 进入讲题页 → 在右侧手写板写出解题步骤 → 点击「提交讲解」→ 左侧出现「小明 + 李老师」围绕该节核心知识点的追问。
3. 点击气泡里的「看这一步」可让画布上对应 `step_id` 的笔迹出现霓虹光晕高亮（对应 `MOBILE_STYLE.md` §5.5）。
4. 「我懂了」结束当前一轮、「下一题」清空画板再来一轮。

更多见仓库根目录的 [`DEMO_SCRIPT.md`](../../DEMO_SCRIPT.md) 与 [`docs/AI_CODE_AGENT_BRIEF.md`](../../docs/AI_CODE_AGENT_BRIEF.md)。
