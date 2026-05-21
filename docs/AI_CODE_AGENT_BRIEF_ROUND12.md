# AI Code Agent 执行指令：第十二轮 · V2 产品闭环与第十一轮缺口补齐

> 本页约束 **第十二轮** 实现。开始前必读：`AGENTS.md`、`MOBILE_STYLE.md`、`项目规划/planV1.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND11.md`、`docs/ROUND11_VERIFICATION.md`。
>
> **背景**：第十一轮已落地大量 **后端 API / DB 表 / 单测**（`round11.py`、`lecture_agent_stream.py` 等），但对照 Round 11 brief 与实机 Demo，仍存在 **「有接口、无 Flutter 产品面」「有适配层、未接主路径」「验收文档过度 PASS」** 三类问题。第十二轮只做这些缺口，**禁止**推倒 Round 10/11 已稳定的讲题主链路。

---

## 0. 本轮定位

| 维度 | 说明 |
|------|------|
| **目标** | §3 任务 **A～Q 全部完成**，使 `DEMO_SCRIPT.md` §14 与 §15 可在 Android 平板 + 后端环境 **完整走通**（非仅 curl 测 API）。 |
| **原则** | 先接主路径再写 fallback；fallback 必须打可观测日志；**禁止**用「第十一轮已 PASS」跳过 UI/接线任务。 |
| **口径** | **无最小集、无可选、无「下轮再做」**；缺 §3 任一项 = 第十二轮未完成。 |
| **不做** | 与 Round 11 §1.6 相同：真实支付、真实物流 API、家长代充值晶石；不删 `chat`/`sessions` 旧路由。 |

**本轮一句话**：**把 Round 11 留在「后端骨架」里的 V2 能力，补成学生端 + 家长端可演示的完整产品闭环，并修正文档/验收口径。**

---

## 1. 第十一轮已完成（勿重复实现）

下列能力 **已有代码**，本轮仅 **扩展 / 接线 / 补 UI**，不要从零重写：

| 领域 | 已有落点 |
|------|----------|
| LLM NDJSON 流式 | `main/app/services/lecture_agent_stream.py`；`live_lecture_session._stream_turns_to_client` |
| 账号 prefs 隔离 | `AuthService.storageNamespace`；`ProgressRepository` / `ReviewRepository.switchUser` |
| 公式 | `flutter_math_fork` → `FormulaText` |
| 实时礼貌 | `lecture_page.dart`：3s 写字不追问、300ms 防抖、角色打断气泡、2.5s/4s |
| 学习同步 | `LearningSyncService.pullAndMerge`；`applyFromServer`；`POST /learning/reviews` |
| 隐私页 | `PrivacyNoticePage` |
| Round11 HTTP API | `main/app/routers/round11.py`：gamification、leaderboard、shop、bounty、replays、upload-image、knowledge/search、parent/children |
| DB 模型 | `main/app/db.py`：`LectureReplayRecord`、`SectionPower`、`CrystalWallet`、`LeaderboardSnapshot`、`RedeemOrder`、`ParentStudentLink` 等 |
| 后端单测 | `test_round11_endpoints.py`、`test_lecture_agent_stream.py`、`test_volc_asr_stream.py`（35 pytest passed 基线） |
| Flutter 单测基线 | `storage_namespace`、`learning_sync_merge`、`gamification_power`、`replay_timeline` 等（67 tests 基线） |

---

## 2. 第十一轮仍缺 / 不实盘项（本轮必须消灭）

> 来源：Round 11 代码审阅 + `ROUND11_VERIFICATION.md` 与实机 Demo 14 对照。

### 2.1 缺口总表（对应 Round 11 任务）

| Round11 | 缺口摘要 | 第十二轮任务 |
|---------|----------|--------------|
| O | `volc_asr_stream.py` **未接入** `live_asr_buffer` / session；启用时返回空文本 | **B** |
| Ob | 无画布 PNG；`hwr` 仅复制 `referenceSteps`；客户端不传 `image_base64` | **C** |
| P | 无讲题结束 `POST /replays`；无回放播放器；家长端无回放入口 | **D** + **E** |
| Q | 无学生端战力/段位展示页；无 `GET /gamification/me` 客户端 | **F** |
| R | 无 `LeaderboardSnapshot` 周结算脚本；榜单纯实时聚合 | **G** |
| S | 无悬赏 Flutter 页（圈错 + 语音 + 提交） | **H** |
| T / U | 无商城/工具局 Flutter 页；兑换后 **penStyle 未应用到白板** | **I** |
| V | 无拍照识题入口；`upload-image` 为硬编码 fallback | **J** |
| W | `_KNOWLEDGE` 内联；**未注入** `lecture_agent` / live prompt | **K** |
| X | 仅 16 章 9 题 + 运行时 stub；无 `pep-junior-math-questions.json` / 生成脚本 | **L** |
| Y | `/parent/children` 有 API；家长端 **无切换孩子** UI；dashboard 未带 `studentId` | **E** + **M** |
| J（P1-10） | 展示名编辑 **仅家长端** | **N** |
| K（P1-11） | 无 `--dart-define=DEBUG_OCR=1` 讲题页面板 | **O** |
| M / 验收 | `AGENTS.md` 仍写 Unicode 公式占位；`ROUND11` 把无 UI 的 API 标 PASS | **P** |
| Demo 14 | 12 条无法在 App 内演示 | **§3-N** 全部可勾选 |

### 2.2 验收口径修正（强制）

第十二轮 `docs/ROUND12_VERIFICATION.md` 必须区分两列：

| 列 | 含义 |
|----|------|
| **API** | curl / pytest 通过 |
| **App Demo** | 平板路径可点击、可看见、可录屏 |

**Round 11 标 PASS 但 App Demo 为 FAIL 的项，本轮必须变为 App Demo PASS**，不得再只写「API 已 PASS」。

---

## 3. 任务清单（A～Q 全部必做）

> 建议 **一任务一 commit**。`git add` 仅本次改动文件（见 `AGENTS.md` 第 0 条）。

---

### 任务 A · 首页 V2 入口与导航壳（学生端）

**目标**：学生在 `HomePage` 能进入悬赏、商城、排行榜、拍照识题、个人战力，无需 curl。

**建议改动**：

- `main/mobile/lib/pages/home_page.dart`：Hero 下或 AppBar 增加入口区（遵循 `MOBILE_STYLE.md`，勿电竞风）：
  - 「今日悬赏」「晶石商城」「排行榜」「拍照识题」「我的战力」
- 新建路由跳转至任务 H/I/G/J/F 对应页面（可先占位 Shell，由后续任务填满内容）
- 可选：`main/mobile/lib/pages/student_hub_page.dart` 聚合入口，避免 `home_page` 过长

**验收**：

- [ ] 冷启动首页可见上述 **5 个**入口，点击均能 `push` 到对应页面（非 SnackBar「开发中」）
- [ ] `dart analyze lib/` 无新增 error

---

### 任务 B · 流式 ASR 接入 Live 主路径（P2-1 实盘）

**目标**：`pause_detected` 前的 transcript 更新，主路径日志 `asr_mode=stream`（配置凭证时）；未配置时 `window_fallback` 且行为与第九轮一致。

**现状问题**：

- `main/app/services/volc_asr_stream.py` 未被 `live_asr_buffer.py` / `live_lecture_session.py` import
- `VolcStreamingAsrClient.accept_chunk` 在 enabled 时返回 **空 text**

**建议改动**：

- `main/app/services/live_asr_buffer.py`：
  - `flush` / `accept_chunk` 路径优先调 `VolcStreamingAsrClient`
  - partial → 回调 `on_partial(text)`；final → 合并进 session `transcript_segments`
  - 日志：`[asr-stream] asr_mode=stream|window_fallback`
- `main/app/services/live_lecture_session.py`：收到 partial 时 `send asr_segment`（`isFinal: false`），与 Round 9 事件契约一致
- `volc_asr_stream.py`：实现真实火山流式 WebSocket/SDK（读 `.env`）；无凭证时 `enabled=False` 并返回 `None` 交还 window ASR
- 更新 `live_asr_buffer.py` 顶部注释（删除「不用流式 ASR」过时描述）
- `main/tests/test_volc_asr_stream.py`：mock WS 返回 partial 文本，断言 session 累积非空

**验收**：

- [ ] 配置 `VOLC_ASR_STREAM_*` 时，live 日志 **主路径** `asr_mode=stream` 且 partial 非空（可 mock）
- [ ] 未配置时 `asr_mode=window_fallback`，讲题不中断
- [ ] Flutter **仍默认不展示**完整 ASR（仅 `DEBUG` 或 `DEBUG_OCR` 类开关可看）
- [ ] pytest 新增/更新用例通过

---

### 任务 C · 商业 HWR：画布出图 + 真实请求体（P2-12）

**目标**：`/ocr/ink mode=hwr` 在收到 **step 区域 PNG base64** 时走商业识别；失败回落 `reference_step` / `template`。

**建议改动**：

- `main/mobile/lib/widgets/hand_canvas.dart`（或 `HandCanvasController`）：
  - `Future<Uint8List?> exportStepPng(String stepId)`：`RepaintBoundary` + `toImage` 裁剪 step 区域
- `main/mobile/lib/services/ocr_service.dart`：每 step 带 `imageBase64`（字段名与后端 Pydantic 对齐）
- `main/app/routers/ocr.py`：
  - `hwr` 分支：有 `OCR_HWR_API_KEY` 时 `httpx` 调供应商（火山/百度等，密钥 `.env.example` 说明）
  - 无 key：明确 `source=template` + `confidence<=0.4`，**禁止**伪装 `source=hwr`
- `live_lecture_service.dart`：snapshot  enrich 仍 debounce 480ms，失败不阻塞

**验收**：

- [ ] Demo 题手写步骤请求体含非空 `imageBase64`（日志可截断预览）
- [ ] 有 key：响应 `source=hwr` 且 `confidence>=0.5`（允许单步失败回落）
- [ ] 无 key：日志说明回落原因，讲题链路不崩
- [ ] 与任务 **O** 的 DEBUG 面板可显示每步 `source/confidence/mode`

---

### 任务 D · 讲题回放：录制上报 + 过程播放器（P2-2）

**目标**：一次 live 或 submit 讲题结束后，家长与学生可播放「音轨 + 笔迹时间轴 + 气泡」过程回放。

**建议改动**：

- 新建 `main/mobile/lib/services/replay_service.dart`：
  - `startSession(sessionId)`；`appendInk(tMs, points)`；`appendTurn(tMs, text, role)`；`appendAudioChunk(base64)`
  - `finishAndUpload()` → `POST /replays`（Bearer）
- `main/mobile/lib/pages/lecture_page.dart` / `live_lecture_service.dart`：
  - 进 live 时生成 `sessionId`；ink/turn/audio 事件带 `tMs`（相对 session 起点）
  - `round_done` / 页 dispose 时 `finishAndUpload`（失败 swallow + debug log）
- 新建 `main/mobile/lib/pages/replay_page.dart`：
  - 播放：音频 `audioplayers` + 画布按 `inkTimeline` 重绘 + 当前气泡高亮
  - 误差：音画同步 ≤500ms（brief 允许）
- `main/mobile/test/replay_timeline_test.dart`：扩展「上传 payload 序列化」用例

**验收**：

- [ ] 完成 16.x live 讲题后，DB/API 能 `GET /replays/{sessionId}` 含非空 `inkTimeline` + `turnsTimeline`
- [ ] `ReplayPage` 可播放且笔迹随时间出现
- [ ] 无回放数据时温和空状态

---

### 任务 E · 家长端：回放列表 + 多孩子切换（P2-11 + P2-2）

**目标**：家长 dashboard 可切换孩子、查看该孩子回放并进入 `ReplayPage`。

**建议改动**：

- `main/mobile/lib/services/parent_service.dart`：
  - `fetchChildren()` → `GET /parent/children`
  - `bindChild(username, nickname)` → `POST /parent/children/bind`
  - `fetchReplays({String? studentId})` → `GET /parent/replays`（query/header 带 active student，与后端对齐）
  - `fetchDashboard({String? studentId})` 同步改
- `main/app/routers/parent.py` 或 `round11.py`：**统一** active student 语义（推荐 `X-Student-Id` header 或 `?studentId=`，两处文档写清）
- `parent_dashboard_page.dart`：
  - AppBar 下拉/横向 chip **切换孩子**
  - 「精彩回放」列表 → 点进 `ReplayPage`
  - 「绑定孩子」入口（用户名 + 确认，调用 bind API）

**验收**：

- [ ] 绑定 2 个孩子后，切换 dashboard 数据不同（掌握度/最近讲题）
- [ ] 孩子 A 的回放 **不会**出现在孩子 B 的列表
- [ ] 家长可点开回放并播放（任务 D 播放器复用）

---

### 任务 F · 学生个人战力中心（P2-3）

**目标**：学生可见费曼战力、段位、本周变化、已装配称号。

**建议改动**：

- `main/mobile/lib/services/gamification_service.dart`：`fetchMe()` → `GET /gamification/me`
- `main/mobile/lib/pages/power_profile_page.dart`（任务 A 的「我的战力」落地）：
  - 展示总战力、段位图标、分 section 战力条
  - 调用 `GET /leaderboard/my-titles` 展示 `equippedTitle`
- `lecture_page.dart` AppBar：小徽章显示当前 section 战力（可选 Chip）

**验收**：

- [ ] 讲题完成或 `power/adjust` 后，战力数字变化（本地刷新或 pull）
- [ ] 跨段位阈值有 Toast 或卡片提示（与 Round 11 Q 一致）

---

### 任务 G · 排行榜页 + 周结算脚本（P2-4）

**目标**：校/区/市/省 Tab 排行榜可演示；周一 0 点（或脚本手动）写入 `LeaderboardSnapshot` 并发放称号。

**建议改动**：

- `main/mobile/lib/pages/leaderboard_page.dart`：
  - Tab：`school` / `district` / `city` / `province`
  - `GET /leaderboard?sectionId=&scope=` 渲染 Top N + 自己名次
  - 称号展示与「装配」按钮 → `PATCH /learning/profile` 写 `equippedTitle`（若后端无专用接口则扩展 profile）
- 新建 `scripts/settle_leaderboard.py`：
  - 读上周 `SectionPower`，按 scope 分组排序，写入 `LeaderboardSnapshot`
  - 幂等：`weekId + scope + sectionId + studentId` 唯一
  - 文档：`deploy.sh` 或 `docs/DEPLOY.md` 增加 cron 示例
- `round11.py` `GET /leaderboard`：优先读 snapshot（有则展示上周榜），无则回退实时聚合（**两种路径都要测**）

**验收**：

- [ ] 脚本跑完后 DB 有 snapshot 行；API 返回与脚本一致
- [ ] 2 个测试账号同校排名可见变化
- [ ] 不同 `city` 的学生 **不**进同一榜

---

### 任务 H · 今日悬赏完整玩法页（P2-5）

**目标**：圈错 + 语音纠错 + 奖励晶石/战力，复用 live ASR（任务 B）与追问（已有 stream）。

**建议改动**：

- `main/mobile/lib/pages/bounty_page.dart`：
  - `GET /bounty/today` 展示 3 题（或轮转的 1 题详情页）
  - 错误解法底图（可用 `CustomPaint` 静态层 + 学生红笔圈选层）
  - 圈选矩形与后端 `errorBox` IoU 判定（客户端可先算，提交 `circledBox`）
  - 麦克风 → live 或短录音 → `transcriptText`；`POST /bounty/submit`
- 完成后 SnackBar 显示晶石/战力奖励，引导去商城（任务 I）

**验收**：

- [ ] 圈对 + 语音说明后 `completed: true`，晶石余额增加（`GET /shop/catalog` 或 wallet 字段）
- [ ] 同日重复提交幂等（不重复刷奖励）

---

### 任务 I · 晶石商城 + 笔迹皮肤生效（P2-6）

**目标**：虚拟商品兑换后，讲题白板可见 penStyle 变化。

**建议改动**：

- `main/mobile/lib/pages/shop_page.dart`：
  - `GET /shop/catalog`；展示余额；`POST /shop/redeem`
  - 分栏：虚拟皮肤 / 跳转工具局（任务 J）
- `main/mobile/lib/services/user_cosmetics_prefs.dart`（或写入 `StudentProfile` sync）：
  - 保存 `equippedPenStyle` / `equippedAvatarFrame`
- `hand_canvas.dart`：根据 `penStyle` 改 stroke 颜色/宽度/阴影（至少 2 款可区分）

**验收**：

- [ ] 兑换扣晶石成功，余额不为负
- [ ] 返回讲题页后笔画样式 **肉眼可辨** 变化
- [ ] 收支可在 UI 查看最近流水（调 ledger API 或 shop 扩展 `GET /shop/ledger`）

---

### 任务 J · 极客学习工具局订单页（P2-7）

**目标**：物理 SKU 兑换申请 + 我的订单状态（pending → shipped）。

**建议改动**：

- `main/mobile/lib/pages/geek_shop_page.dart`（或 shop 第二 Tab）：
  - 读 `data/shop/geek_skus.json`（若尚无则后端静态 + 同步到 repo）
  - 表单：收货人/地址/电话；`POST /shop/redeem` type=physical → `RedeemOrder`
  - `GET /shop/orders` 列表
- 后端：若无 `GET /shop/orders` 则在 `round11.py` 补齐（学生看自己订单）

**验收**：

- [ ] 提交后订单 `pending`，晶石已扣
- [ ] 脚本或管理 API 改 `shipped` 后，Flutter 列表刷新可见（`AnimatedBuilder` 或 pull refresh）

---

### 任务 K · 课本知识库文件 + Agent 注入（P2-9）

**目标**：第十六章知识片段可检索，且 **live/submit 的 LLM prompt 可见 knowledge hits**。

**建议改动**：

- 新建 `data/knowledge/pep-g8-down-ch16_chunks.json`（≥10 条，含 `sectionId` / `title` / `text`）
- `main/app/services/knowledge_index.py`：启动加载；cosine 或关键词打分（与现 `_score` 等价即可）
- `round11.py` `/knowledge/search` 改为调 `knowledge_index`（删除内联 `_KNOWLEDGE` 硬编码）
- `lecture_agent.py` + `lecture_agent_stream.py`：
  - 根据 `section_id` + `question_prompt` 取 topK 片段拼入 system prompt
  - 日志：`[lecture-agent] knowledge_hits=3 section=...`
- 可选：`power_profile_page` 或 debug 页展示 search 结果

**验收**：

- [ ] `POST /knowledge/search` 返回 chunks 来自 JSON 文件
- [ ] 讲题时后端日志 `knowledge_hits>=1`（mock LLM 时可检查 prompt 构建单测）
- [ ] 追问内容与检索片段主题一致（Demo 可人工核对 16.2 同类根式）

---

### 任务 L · 全册 90 节题库数据化（P2-10）

**目标**：非运行时 stub；仓库内有可 diff 的题库文件；每节 ≥1 题。

**建议改动**：

- 新建 `scripts/generate_section_questions.py`：
  - 读 `data/curriculum/pep-junior-math.json`
  - 为 **90 节**各生成 1～3 题（`quality: stub` 标签允许，但 `questionId/sectionId/prompt/referenceSteps` 齐全）
  - 输出 `data/questions/pep-junior-math-questions.json`
- `mock_lecture_repository.dart`：启动时加载 asset JSON（`pubspec.yaml` 注册 asset）
- `questionCountForSection`：以 JSON 为准；无题节才 fallback stub
- 后端可选：`GET /questions?sectionId=` 读同一 JSON（与 Flutter 一致）

**验收**：

- [ ] JSON 内 **90 个** distinct `sectionId` 各有 ≥1 题
- [ ] 随机抽 5 个 **非 16 章** program 节，首页题量徽标 ≥1，可进讲题并完成一轮
- [ ] `flutter test` 中 `mock_lecture_repository_test` 更新断言

---

### 任务 M · 拍照识题闭环（P2-8）

**目标**：相册/相机 → 上传 → 推荐 section → 进入 `LecturePage`。

**建议改动**：

- `pubspec.yaml`：`image_picker`（容器 mirror 安装）
- `main/mobile/lib/pages/photo_question_page.dart`：
  - 选图 → multipart `POST /questions/upload-image`
  - 展示 `sectionId` / `confidence` / `questionPrompt`；可手动改章节
  - 确认后 `push LecturePage(section, initialQuestionId 可选)`
- `round11.py` `upload-image`：有 vision key 时调 Kimi/火山 vision；无则 **明确** `vision_fallback` 且允许手动选章（禁止静默永远 16.3）

**验收**：

- [ ] 选二次根式图片推荐到 16.x（或 fallback 下手动选章仍可讲题）
- [ ] 识别失败有温和文案，不 crash

---

### 任务 N · 学生端资料编辑（P1-10 补齐）

**目标**：学生本人可改展示名/年级/学校省市（排行榜用）。

**建议改动**：

- `main/mobile/lib/pages/student_profile_edit_page.dart`：
  - `GET/PATCH /learning/profile`
  - 字段：`displayName`、`grade`、`schoolName`、`province`、`city`、`district`
- 入口：首页「我的战力」页或设置

**验收**：

- [ ] 修改后首页/讲题页/家长端（sync 后）可见新展示名
- [ ] 排行榜 scope 依赖的地区字段保存成功

---

### 任务 O · DEBUG_OCR 可观测面板（P1-11 补齐）

**目标**：`flutter run --dart-define=DEBUG_OCR=1` 时讲题页展示每步 OCR 结果。

**建议改动**：

- `lecture_page.dart`：
  - `const _debugOcr = bool.fromEnvironment('DEBUG_OCR');`
  - 底部 `Collapsible` 列表：`stepId | latex | source | confidence | mode`
- Release 默认关闭；`MAC_LOCAL_DEV.md` 补充一行命令示例

**验收**：

- [ ] Debug 开启可见面板；Release 无面板
- [ ] Demo 13 第 11 条可勾选

---

### 任务 P · 文档与验收口径修正（M + 诚实 PASS）

**目标**：文档与代码一致；区分 API PASS vs App Demo PASS。

**必须更新**：

| 文件 | 内容 |
|------|------|
| `AGENTS.md` | 删除/改写「公式 Unicode 占位」；追加 Round 12 踩坑：回放时间轴、流式 ASR 接线、商城皮肤 prefs |
| `项目规划/planV1.md` | 实现状态表增加列 **「App 可演示」**；第十一轮标「API」的改准确 |
| `README.md` | 第十二轮索引；新页面与新 API 说明 |
| `docs/MAC_LOCAL_DEV.md` | DEBUG_OCR、image_picker 权限、回放存储路径 |
| `docs/ROUND12_VERIFICATION.md` | **新建**，模板见 §3-N5 |
| `DEMO_SCRIPT.md` | 新增 **§15 · 第十二轮 V2 产品闭环**（可演示 checklist） |
| `docs/ROUND11_VERIFICATION.md` | 顶部加 **免责声明**：第十一轮 PASS 仅指 API/单测，产品闭环见 Round 12 |

**验收**：

- [ ] 无互相矛盾的「已落地」表述
- [ ] `ROUND12` 中 App Demo 列无空白 FAIL（允许外部 key 行注明 fallback，但 **禁止** NOT_IMPLEMENTED）

---

### 任务 Q · 测试与回归（N）

#### Q1 · 后端

- 扩展 `test_round11_endpoints.py` 或新建 `test_round12_*.py`：
  - leaderboard snapshot 脚本产物被 API 读取
  - knowledge 注入后 prompt 含 chunk 关键词（monkeypatch）
  - replay POST 后 GET 时间轴字段完整
  - OCR hwr 请求体含 `imageBase64` 时走 hwr 分支（mock httpx）
- `test_volc_asr_stream.py`：partial 文本进入 session（mock）
- 全量 `pytest main/tests` **≥ 基线 35** 且全绿

#### Q2 · Flutter

- 新建/扩展：
  - `test/replay_service_test.dart`
  - `test/mock_lecture_questions_asset_test.dart`（90 节）
  - `test/shop_redeem_payload_test.dart`（可选）
- 全量 `flutter test` **≥ 基线 67** 且全绿
- `dart analyze lib/ test/` 0 error

#### Q3 · Demo §15 checklist（写入 `DEMO_SCRIPT.md`）

1. 首页 5 个 V2 入口均可进入对应页。
2. Live 讲题结束 → 家长端「精彩回放」可播放（音+笔+气泡）。
3. 切换 2 个孩子 dashboard 数据不同。
4. 排行榜校/市 Tab + 脚本结算后称号变化可演示。
5. 今日悬赏圈错提交拿晶石。
6. 商城兑换皮肤 → 讲题笔画变色。
7. 工具局下单 pending → 列表可见。
8. 拍照识题进入 16.x 讲题。
9. 非 16 章节目录抽 1 节完成讲题。
10. 学生端改展示名后家长端可见。
11. `DEBUG_OCR=1` 可见 step source/confidence。
12. `ROUND12_VERIFICATION.md` App Demo 列全 PASS。

---

## 4. 建议执行顺序

| 顺序 | 任务 | 说明 |
|------|------|------|
| 1 | L 全册题库 JSON | 后续讲题/识题依赖 |
| 2 | K 知识库 + Agent 注入 | 与讲题质量相关 |
| 3 | B 流式 ASR 接线 | 悬赏/ live 依赖 |
| 4 | C HWR 画布 | 独立 |
| 5 | D 回放录制 + 播放器 | |
| 6 | E 家长回放 + 多孩子 | 依赖 D |
| 7 | F 战力页 | |
| 8 | G 排行榜 + 脚本 | 依赖 F |
| 9 | I 商城 + 皮肤 | |
| 10 | J 工具局订单 | 依赖 I |
| 11 | H 悬赏页 | 依赖 B、I |
| 12 | M 拍照识题 | 依赖 L |
| 13 | A 首页入口 | 串联 H/I/G/J/F |
| 14 | N 学生资料 | |
| 15 | O DEBUG_OCR | |
| 16 | P 文档 | |
| 17 | Q 测试 + §15 + ROUND12 报告 | 最后 |

---

## 5. 完成后同步清单

- [ ] §3 任务 **A～Q** 均已实现。
- [ ] `docs/ROUND12_VERIFICATION.md`：**API** 与 **App Demo** 列均 PASS（或外部依赖行注明 fallback）。
- [ ] `DEMO_SCRIPT.md` **§15** 12 条可在平板走通。
- [ ] `pytest` / `flutter test` 全绿且不少于 Round 11 基线。
- [ ] `AGENTS.md` / `planV1.md` / `README.md` 已同步。

---

## 6. 反例对照

| ❌ 错误 | ✅ 正确 |
|--------|--------|
| 只测 `POST /replays` curl 就算 P2-2 完成 | 家长端能点回放并播放 |
| `volc_asr_stream` 文件存在但不 import | session 主路径调 stream client |
| hwr 仍复制 referenceSteps 却标 `source=hwr` | 无图或无 key 时标 `template` / `reference_step` |
| 90 节靠 `_stubQuestionForSection` 动态生成 | 仓库有 `pep-junior-math-questions.json` |
| `ROUND12` 只填 API 列 PASS | App Demo 列必须勾选 |
| 商城兑换后无任何 UI 变化 | 白板 penStyle 肉眼可变 |
| 复刻 Round 11 整文件重写 | 在 `round11.py` 上扩展 |

---

## 7. 参考锚点

| 主题 | 路径 |
|------|------|
| Round11 API | `main/app/routers/round11.py` |
| ASR 窗口（待接 stream） | `main/app/services/live_asr_buffer.py` |
| Stream ASR 适配（待实装） | `main/app/services/volc_asr_stream.py` |
| Live session | `main/app/services/live_lecture_session.py` |
| OCR | `main/app/routers/ocr.py`；`ocr_service.dart` |
| 家长端 | `parent_dashboard_page.dart`；`parent_service.dart` |
| 题库 | `mock_lecture_repository.dart` |
| Round11 验收（API 向） | `docs/ROUND11_VERIFICATION.md` |

---

**本轮结束标志（唯一口径）**：

1. §3 **A～Q 全部完成**，且 `DEMO_SCRIPT.md` **§15** 十二条可在 Android 平板演示录屏。
2. `ROUND12_VERIFICATION.md` 中 **App Demo 列无 FAIL**（允许 KIMI/VOLC/OCR 外部 key 行写 fallback 验证，**禁止** NOT_IMPLEMENTED / SKIPPED）。
3. Round 11 已有 API **保持可用**；全量 pytest + flutter test 不低于基线且全绿。
