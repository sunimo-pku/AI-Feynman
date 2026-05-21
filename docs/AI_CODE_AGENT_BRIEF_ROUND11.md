# AI Code Agent 执行指令：第十一轮全量收口（V1 缺口 + planV1 V2 能力）

> 本页用于约束 AI Code Agent 的第十一轮实现。开始写代码前，必须先阅读 `AGENTS.md`、`项目规划/planV1.md`、`MOBILE_STYLE.md`、`docs/AI_CODE_AGENT_BRIEF.md`、`docs/AI_CODE_AGENT_BRIEF_ROUND2.md` 至 `docs/AI_CODE_AGENT_BRIEF_ROUND10.md`，并以本页作为**唯一**任务边界。
>
> **背景**：第十轮已落地学生端实时双工、家长端、学习数据表等主体；但对照第十轮验收、`planV1.md` 全文与代码审阅，仍有 **V1 硬缺口** 与 **planV1 中尚未实现的 V2 能力**（游戏化、视频/过程回放、流式 ASR、悬赏挑错、晶石商城、地理排行榜、拍照识题、知识库检索、全册题库扩展等）。
>
> **口径（用户确认）**：**无最小集、无可选任务、无「V2 下一轮再做」**——§3 任务 **A～Z 全部完成** 才算第十一轮结束。

---

## 0. 本轮定位

| 维度 | 说明 |
|------|------|
| **目标** | **§3 任务 A～Z 全部完成**。覆盖 §1.2 P0、§1.3 P1、§1.5 P2（planV1 V2）全部缺口 ID。 |
| **原则** | 音频 + 白板仍是讲题主输入；外部 API 失败走 fallback，**不能**用 fallback 顶替未实现模块。 |
| **执行顺序** | 建议按 §5 顺序分 commit；**缺 A～Z 任一项 = 本轮未完成**。 |

**本轮一句话**：**把 `planV1.md` 里写明的学生端、家长端、游戏化、回放、流式 ASR、悬赏、商城、识题、知识库与全册题库扩展，在本轮全部落地并验收。**

---

## 1. 当前进度判断（第十轮之后）

### 1.1 已完成（勿推倒重来）

- 学生端：目录、讲题页、白板、16.1～16.3 题库、本地进度/回顾、实时双工 WS、`/ocr/ink` 规则版、TTS 淡出、断连/无麦文字兜底。
- 后端：`StudentProfile` / `LearningProgress` / `LectureReview` / `LectureSessionRecord`；`/learning/*`、`/parent/*`；`/lecture/live` 可选 token 落库。
- 家长端：`ParentDashboardPage`、海报 Sheet、弱项/最近讲题/教师建议。
- 测试：`test_round10_endpoints.py`（HTTP 11 用例）、live session 单测、部分 Flutter 单测。

### 1.2 第十轮仍缺的硬项（本轮 P0）

| ID | 缺口 | 现状 |
|----|------|------|
| P0-1 | 真 token 级 LLM 流式 | `live_lecture_session` 仍 `generate_lecture_turns` 整段返回后 `_split_text_into_deltas` |
| P0-2 | 登录后本地数据隔离 | `shared_preferences` key 全局固定，换账号会串数据 |
| P0-3 | 根目录 `requirements.txt` | README 引用但仓库缺失 |
| P0-4 | `planV1.md` V1 完成度标注 | 未更新 |
| P0-5 | 部署/WebSocket 文档 | `deploy.sh` 无反代说明；`MAC_LOCAL_DEV.md` 无 WS/nginx |
| P0-6 | 全链路验收记录 | 缺可执行的验收清单与（尽量）自动化测试 |

### 1.3 半完成 / 规划对齐项（本轮 P1）

| ID | 缺口 | 现状 |
|----|------|------|
| P1-1 | 公式原生渲染 | `formula_text.dart` Unicode 占位 |
| P1-2 | 写字中不追问 | 静音即 `pause_detected`，未结合最近笔画 |
| P1-3 | 声音打断 300ms 防抖 | 音量超阈即打断，仅 700ms 冷却 |
| P1-4 | 打断社交化气泡 | 仅系统气泡，无角色礼貌文案 |
| P1-5 | 多角色 TTS 音色 | 全局单一 `VOLC_DEFAULT_SPEAKER` |
| P1-6 | 冷启动从服务端恢复 | 仅 upload sync + 粗略回灌 |
| P1-7 | 进度精确同步 | `applyCompleted` 差值近似，非覆盖 |
| P1-8 | 隐私/权限说明页 | 仅系统麦克风弹窗 |
| P1-9 | `POST /learning/reviews` | brief 曾列，现仅 sync 内 upsert |
| P1-10 | 学生资料展示名 | DB 有字段，无编辑 UI |
| P1-11 | OCR 可观测性 | 规则版已有，需 confidence/source 进日志与 debug |
| P1-12 | 思维断档提示（2.5s）/ 讲完收束（4s） | planV1 §4.3 未实现 |

### 1.5 planV1 V2 能力缺口（本轮 P2，必须全部完成）

| ID | 能力（planV1 章节） | 现状 |
|----|---------------------|------|
| P2-1 | **流式 ASR SDK**（§4.1 持续采集 ~200ms 级） | 仅 2.5s 窗口聚合 + 文件式火山 ASR |
| P2-2 | **精彩讲题回放**（家长端 §6 视频/过程） | 无回放存储与播放 |
| P2-3 | **费曼战力 + 段位徽章**（§5.6.1） | 无 |
| P2-4 | **地理排行榜** 校/区/市/省（§5.6.2） | 无 |
| P2-5 | **今日悬赏 · 挑错**（§5.6.3） | 无 |
| P2-6 | **费曼晶石 + 虚拟商城兑换**（§5.6.3～5.6.5） | 无 |
| P2-7 | **极客学习工具局 · 兑换下单流**（§5.6.5） | 无实物订单流 |
| P2-8 | **拍照识题 + 知识点归属**（§5.2） | 无 |
| P2-9 | **课本向量检索 / Agent 工具**（§5.2） | 无 |
| P2-10 | **全册章节题库扩展**（§5.2 壳子做全） | 仅 16 章有题 |
| P2-11 | **多孩子 · 家长-子账号绑定** | 单 User=学生 |
| P2-12 | **商业级 OCR / 画布出图识别** | 仅规则版 `/ocr/ink` |
| P2-13 | **掌握度驱动出题难度**（§5.3） | 题库有难度标签，无自适应 |

### 1.6 仅下列不做（极窄，其余一律在本轮实现）

| 不做 | 说明 |
|------|------|
| 真实支付通道 | 不接微信/支付宝/Apple IAP；晶石**只能**靠玩法获得 |
| 真实物流 API | 兑换走「申请单 + 状态流转」；可 Mock 发货，不对接快递公司 |
| 家长代充值/打赏 | 禁止任何「给钱买晶石」入口 |
| 重构删除 `chat`/`sessions` 旧路由 | 可保留不动，本轮不清理历史模块 |

**原先误标为「V2 不做」的下列能力，本轮必须做**：游戏化、排行榜、悬赏、晶石商城、实物兑换申请流、视频/过程回放、流式 ASR SDK、拍照识题、向量 RAG、全册题库扩展、多孩子绑定、商业 OCR 升级。

---

## 2. 本轮目标与验收总定义

### 2.1 完成后必须满足（任务 A～Z 全覆盖）

下表与 §1.2 / §1.3 / §1.5 缺口 ID **一一对应**；**全部 PASS** 才算本轮结束。

| 缺口 ID | 任务 | 完成判定（摘要） |
|---------|------|------------------|
| P0-1 | A | Live 主路径为模型流/NDJSON；切片仅 `stream_fallback` |
| P0-2 | B | 本地 progress/review 按用户 namespace 隔离 |
| P0-3 | C | `requirements.txt` 可安装且文档路径统一 |
| P0-4 | M | `planV1.md` 实现状态表（含 V2 已落地） |
| P0-5 | M | 部署文档含 WS、nginx、流式 ASR 超时 |
| P0-6 | N | 全量测试 + `ROUND11_VERIFICATION.md` + `DEMO_SCRIPT` §13～14 |
| P1-1 | D | `flutter_math_fork` 全站公式 |
| P1-2～4 | E | 写字不追问、300ms 防抖、角色打断气泡 |
| P1-5 | F | 四角色 TTS |
| P1-6～7 | G | pull + 精确覆盖 |
| P1-8 | H | 隐私说明页 |
| P1-9 | I | `POST /learning/reviews` |
| P1-10 | J | 展示名/年级编辑 |
| P1-11 | K | OCR debug 可观测 |
| P1-12 | L | 2.5s 提示 + 4s 收束 |
| P2-1 | O | 火山（或等价）**流式 ASR** 接入 live session |
| P2-2 | P | 讲题**过程回放**（音轨+笔迹+气泡时间轴）家长端可播 |
| P2-3 | Q | 费曼战力、段位、个人主页徽章 |
| P2-4 | R | 校/区/市/省排行榜 + 周结算 + 称号装配 |
| P2-5 | S | 今日悬赏 3 题：圈错 + 语音纠错 + 奖励 |
| P2-6 | T | 费曼晶石余额、收支流水、商城兑换 |
| P2-7 | U | 极客学习工具局 SKU 列表 + 晶石兑换申请单 |
| P2-8 | V | 拍照识题上传 + 知识点/章节推荐 |
| P2-9 | W | 第十六章（最低）向量索引 + Agent 检索 tool |
| P2-10 | X | 全册 90 节各 ≥1 道题（可练习节 `available`） |
| P2-11 | Y | 家长账号下挂多个学生 Profile |
| P2-12 | Ob | 画布出图 + 商业 OCR/HWR 接入 |
| P2-13 | AA | 按掌握度/战力推荐题目难度 |

**实时与体验硬指标（与上表同时满足）**：

1. **Live 追问**：thinking 后首条 `agent_turn_delta` **≤8s**（Kimi 可用时）；主路径日志 `source=llm_stream`。
2. **换账号**：userA 进度/回顾不出现在 userB；logout 不删他号 key；userA 再登录数据仍在。
3. **公式**：`\sqrt{}`、`\frac{}`、上下标在讲题/回顾/家长端正确渲染。
4. **测试**：`test_lecture_agent_stream.py`、`test_round11_*.py`（或扩展 round10）、Flutter 单测含 `storage_namespace`、`learning_sync_merge`、`parent_dashboard_payload` **全部存在且通过**。

### 2.2 运行时 fallback（不是范围缩水）

以下仅指**外部依赖失败时**的兜底行为；**不能**因为实现了 fallback 就跳过 §3 主功能实现。

| 场景 | 必须行为 |
|------|----------|
| Kimi 流式解析失败/超时 | 自动 `stream_fallback` 切片 + 日志；**仍须先实现并默认走流式主路径** |
| OCR | 继续规则版 + `referenceSteps`；日志/UI(debug) 标 `source` 与 `confidence` |
| `/ocr/ink` 请求失败 | 空 latex 上送，不阻塞讲题 |
| TTS 某角色 speaker 不可用 | 回退默认 speaker + 日志；**仍须实现四角色映射** |
| 流式 ASR 不可用 | 回退 2.5s 窗口 ASR + 日志；**仍须实现流式 SDK 主路径** |
| 回放视频编码失败 | 回退「过程回放播放器」（笔迹+音频+字幕），禁止无回放入口 |

---

## 3. 任务清单（A～Z 全部必做）

> **口径**：下列 **22 个任务（A～Z，含 O、O₂、AA）全部完成** 后，方可填写 `ROUND11_VERIFICATION.md`。不存在最小集、可选、跳过。
>
> 建议 **一任务一 commit**（`AGENTS.md` 第 0 条）。任务间可并行，**不得**合并省略验收项。

---

### 任务 A · P0-1 真 LLM 流式（后端 + WS 协议不变）

**目标**：`pause_detected` 后，前端 `agent_turn_delta` 主要来自 Kimi streaming，而不是整段 mock 切片。

**建议改动文件**：

- 新增 `main/app/services/lecture_agent_stream.py`
- 修改 `main/app/services/live_lecture_session.py`（`_on_pause_detected` / `_stream_turns_to_client`）
- 修改 `main/app/services/lecture_agent.py`（抽取公共 prompt / 解析，供 stream 与 fallback 共用）
- 新增 `main/tests/test_lecture_agent_stream.py`

**实现策略（二选一，必须落地其一；仓库默认采用方案 B）**：

**方案 A · OpenAI SDK `stream=True` + 增量 JSON 解析**

- `kimi_client.chat.completions.create(..., stream=True)`，累积 `content` delta。
- 边收边用 `ijson` 或手写状态机解析 NDJSON/JSON 中的 `turns[].text`。
- 每解析出一段可读 text，立即 `send agent_turn_delta`（不必等 turn 结束）。

**方案 B · NDJSON 行协议（推荐，与第十轮 brief §10 一致）**

- 新增 system 补充：「只输出 NDJSON，每行一个对象，`type` 为 `turn_start` / `delta` / `turn_done` / `round_meta`」。
- `lecture_agent_stream.generate_turn_events(...)` 为 **generator**，yield `dict`。
- `live_lecture_session` 消费 generator：
  - `turn_start` → `agent_turn_start`
  - `delta` → `agent_turn_delta`
  - `turn_done` → `agent_turn_done`
  - 最后一行 `round_meta` 含 `status` / `masteryDelta` → `round_done`
- **仍保留** `response_format=json_object` 时改关或改 prompt-only；若 Moonshot 流式不支持 json_object，以 NDJSON 纯文本为准。

**硬性约束（沿用 AGENTS.md 踩坑）**：

- `kimi-k2.6` + `extra_body={"thinking":{"type":"disabled"}}` + `temperature=0.6`。
- `max_retries=0`，timeout 28s，线程池 `run_in_executor` 用 lambda 包关键字参数。
- `highlightStepIds` 白名单过滤仍在 **流结束后** 或 **每个 turn_start** 时过滤。
- 解析失败 / 超时 → 调用现有 `generate_lecture_turns` + `_split_text_into_deltas`，日志 `source=stream_fallback`。

**验收**：

- [ ] **正常路径**（Kimi 可用）：日志 `source=llm_stream`，且**不能**全程只有 `source=stream_fallback`。
- [ ] thinking→首 delta 体感 ≤8s（Kimi 慢时仍显示 thinking）。
- [ ] `test_lecture_agent_stream.py`：fake stream 喂入，断言 `turn_start → delta* → turn_done` 顺序。
- [ ] `stream_fallback` 单测或 monkeypatch：仅当流式解析失败时触发切片，且打日志。
- [ ] 学生 `student_interrupt` 仍能截断后续 delta（沿用 `_interrupt_event`）。

---

### 任务 B · P0-2 账号级本地数据隔离

**目标**：`ProgressRepository` / `ReviewRepository` / 相关 prefs key 带 `userId` 或 `username` 后缀；未登录用 `guest` 桶。

**建议改动文件**：

- `main/mobile/lib/services/auth_service.dart`（暴露 `storageNamespace`）
- `main/mobile/lib/services/progress_repository.dart`
- `main/mobile/lib/services/review_repository.dart`
- `main/mobile/lib/pages/home_page.dart`、`lecture_page.dart`（logout 后 `load()` 刷新）
- 修改 `test/progress_repository_test.dart`、`test/review_repository_test.dart`
- 新增 `test/storage_namespace_test.dart`

**规则**：

```text
guest  → ai_feynman.section_progress.v1.guest
user42 → ai_feynman.section_progress.v1.user42
```

- `AuthService.login` 成功：`ProgressRepository.instance.switchUser(...)` + `ReviewRepository.instance.switchUser(...)`：清内存 cache → 读新 key → `notifyListeners`。
- `logout`：切回 `guest`，**不** delete 旧 user key（保留离线数据）。
- `LearningSyncService`：仅同步当前 namespace 对应数据。

**验收**：

- [ ] 单测：A 用户写入 progress，B 用户 login 后 `progressFor` 为 empty/0，A 再 login 数据仍在。
- [ ] 家长端看到的仍是服务端合并结果（与本地 namespace 无关）。

---

### 任务 C · P0-3 补齐 `requirements.txt`

**目标**：仓库根目录或 `main/requirements.txt` 与 `main/app` 实际 import 一致，README 路径统一。

**内容至少包含**（版本可用 `pip freeze` 对齐当前环境）：

- `fastapi`, `uvicorn[standard]`, `sqlalchemy`, `pydantic`, `python-jose` 或项目实际 JWT 库
- `openai`（Kimi SDK）
- `httpx`, `python-multipart`
- 测试：`pytest`, `httpx`（TestClient）

**验收**：

- [ ] 干净 venv `pip install -r ...` 后 `uvicorn app.main:app` 可启动。
- [ ] README / `MAC_LOCAL_DEV.md` 路径与文件位置一致（二选一：根目录 vs `main/requirements.txt`，全文统一）。

---

### 任务 D · P1-1 公式渲染 `flutter_math_fork`

**目标**：替换或包装 `FormulaText`，符合 `MOBILE_STYLE.md` §4.1。

**建议改动文件**：

- `main/mobile/pubspec.yaml`（`flutter_math_fork`；容器内 `PUB_HOSTED_URL` 镜像）
- `main/mobile/lib/widgets/formula_text.dart`
- 全项目 `FormulaText(` 调用点回归（讲题气泡、回顾卡、家长端题面）

**规则**：

- 支持 `$...$`、`$$...$$`、`\(...\)`、`\[...\]` 预处理（与 AGENTS.md 一致）。
- 保留极短纯中文 fallback：无 `$` 且无 `\` 时走 `Text`。
- 性能：列表内公式组件加 `RepaintBoundary`（回顾列表）。

**验收**：

- [ ] `16.3` 题面 `\sqrt{12}-\sqrt{27}`、分式 `\frac{a}{b}` 显示正常。
- [ ] `dart analyze` 无新增 error。

---

### 任务 E · P1-2 / P1-3 / P1-4 实时交互对齐 planV1

#### E1 · 写字中不追问

**文件**：`lecture_page.dart`、`hand_canvas.dart`（若需暴露「最近笔画时间」）

- `HandCanvasController` 增加 `lastStrokeAt`（每次 addStroke 更新）。
- `_onAudioPause`：若 `DateTime.now() - lastStrokeAt < 3s`，**不发** `pause_detected`，面板保持「正在听你讲…」。
- 手动「我讲到这里」不受此限制。

#### E2 · 300ms 人声打断防抖

**文件**：`audio_stream_service.dart` 或 `lecture_page.dart`

- 维护 `_voiceAboveThresholdSince`；仅当连续 ≥300ms 超阈且 AI 在播/说，才 `_maybeInterruptAi(reason: voice)`。
- 保留 700ms interrupt cooldown。

#### E3 · 角色化打断气泡

**文件**：`lecture_page.dart`

- 打断时根据**当前被打断的 turn role** 插入模板气泡，例如：
  - 小明：「没事，你继续说，我听着。」
  - 李老师：「你有新想法啦，慢慢讲。」
- **必须**插入角色模板气泡；**禁止**仅保留泛化系统句作为唯一打断反馈（可额外保留一条极短系统提示，但不可替代角色气泡）。

**验收**：

- [ ] 边写边停说 1.5s：不触发 AI（有笔画 3s 内）。
- [ ] TTS 播放时短促「嗯」<300ms：不打断；连续说话 ≥300ms：打断 + 淡出。
- [ ] 打断后可见角色气泡（非仅系统）。

---

### 任务 F · P1-5 多角色 TTS 音色（四角色全覆盖）

**文件**：

- `main/app/config.py`（`SPEAKER_BY_ROLE` 映射，四个 role 各一条）
- `main/app/routers/tts.py`（请求体 **必须** 支持 `role` 或 `speaker`）
- `main/mobile/lib/services/live_lecture_service.dart`（`requestTts(text, role: ...)` 按 turn 传 role）

**映射要求**：

| role | 要求 |
|------|------|
| xiaoming | 独立 speaker id（偏童声/同学） |
| daxiong | 独立 speaker id（与 xiaoming、teacher 不同） |
| monitor | 独立 speaker id（与上述均不同） |
| teacher | 独立 speaker id（偏温和教师） |

**验收**：

- [ ] 同一轮多 turn 时，日志中至少出现 **3 种不同** `speaker`（四角色映射全部配置）。
- [ ] 手工或 Demo：小明 vs 李老师 TTS 可听出差异。

---

### 任务 G · P1-6 / P1-7 学习数据「拉取 + 精确覆盖」

#### G1 · 冷启动 pull

**后端**：已有 `GET /learning/progress`、`GET /learning/reviews`。

**前端** `LearningSyncService`：

- 新增 `pullAndMerge()`：`login` 后 / `HomePage.initState` 已登录时调用。
- 顺序：`GET progress` + `GET reviews` → 与本地 merge（server 高者胜，与 sync 策略一致）。

#### G2 · 精确覆盖模式（必做）

- 新增 `POST /learning/progress/overwrite` **或** 在 `POST /learning/progress/sync` 请求体增加 `"mode": "merge" | "overwrite"`（二选一实现，**必须**有一种对外可用）。
- `overwrite` / pull 合并：服务端行 **原样** 写入本地 `SectionProgress`（新增 `ProgressRepository.applyFromServer(...)`，**禁止**再用 `applyCompleted` 差值近似覆盖 server 高分）。

**验收**：

- [ ] 设备 A 完成 3 轮 → sync → 设备 B login pull → 显示 3 轮/对应分数。
- [ ] 单测或手工：server 90 分、本地 10 分，pull 后本地 90。

---

### 任务 H · P1-8 隐私与权限说明页

**文件**：新增 `main/mobile/lib/pages/privacy_notice_page.dart`

- 静态文案：录音用途、数据存哪（本地+服务端）、家长可见范围、如何删本地数据（logout/清数据指引）。
- 入口：首页 About / 家长端设置 / 首次申请麦克风前 **一次** 轻提示（`SharedPreferences` `privacy_ack_v1`）。

**验收**：

- [ ] 首次点「开始讲题」可先见简短说明再弹系统麦克风权限。

---

### 任务 I · P1-9 `POST /learning/reviews`（必做）

**文件**：`main/app/routers/learning.py`、`learning_sync_service.dart`（或 `review_repository.dart`）

- `POST /learning/reviews`：单条 upsert，body 与 sync 内 review item 同形；`require_user`；`client_id` 幂等。
- Flutter：`ReviewRepository.append` 成功后 **必须** fire-and-forget 调 POST（失败只 `developer.log`，不弹红条）。

**验收**：

- [ ] `test_round10_endpoints.py` 或新测例覆盖 POST 单条。

---

### 任务 J · P1-10 学生展示名

**后端**：`PATCH /learning/profile` 或 `POST /auth/profile` 更新 `StudentProfile.display_name`、`grade`。

**前端**：`AuthPage` 或家长端顶部「编辑昵称」→ 保存后 dashboard `studentName` 更新。

**验收**：

- [ ] 改名后家长端海报与 dashboard 显示新名。

---

### 任务 K · P1-11 OCR 可观测 + Debug

**文件**：`ocr.py`、`live_lecture_service.dart`、`lecture_page.dart`

- Debug 开关 `--dart-define=DEBUG_OCR=1`：讲题页底部 **仅 Debug** 显示每步 `latex (confidence/source)`。
- 后端日志 `[ocr-ink] step_1 source=reference_step conf=0.72`。

**验收**：

- [ ] 默认 UI 仍不展示 ASR 全文、不展示 OCR 面板。

---

### 任务 L · P1-12 思维断档提示 + 讲完收束（两项都做）

**文件**：`lecture_page.dart`；必要时 `live_lecture_session.py`（若采用服务端 `session_wrap_up`）

| 触发 | 行为 | 必做 |
|------|------|------|
| 静音 ≥2.5s、且 3s 内无新笔画、且未 thinking | 前端系统气泡（模板，不调 LLM）：如「卡住了？想想被开方数要满足什么条件。」 | ✅ |
| 静音 ≥4s、白板 3s 无更新、且有 ≥1 step、且未 thinking | 自动 `pause_detected(silenceMs=4000)` 触发 AI 追问 | ✅ |

**注意**：与 E1 共用 `lastStrokeAt`；2.5s 提示与 4s 收束**互不替代**，须同时可演示。

**验收**：

- [ ] 停说停写 2.5s：出现断档提示气泡，**不**调用 LLM。
- [ ] 停说停写 4s：进入 thinking，随后走任务 A 流式追问。

---

### 任务 O · P2-1 流式 ASR SDK（替换窗口聚合为主路径）

**目标**：`planV1.md` §4.1「200ms 级流式文本」在工程上可感知；`LiveAsrBuffer` 窗口聚合仅作 fallback。

**建议改动**：

- 新增 `main/app/services/volc_asr_stream.py`（或扩展现有 `volc_asr.py`）
- 修改 `live_asr_buffer.py` / `live_lecture_session.py`：主路径消费**部分识别结果**（partial/final）
- `.env.example`：`VOLC_ASR_STREAM_APP_ID` 等（与文件式 ASR 区分）

**实现要点**：

- 前端仍发 `audio_chunk`；后端接入火山**流式**识别（WebSocket 或 SDK 文档规定的流式 API）。
- 每收到 partial transcript → `asr_segment`（可带 `isFinal: false`）；final → `isFinal: true` 并写入 `transcriptSegments`。
- 目标延迟：partial 相对音频实时 **≤1s**（受网络约束）；日志打 `asr_mode=stream`。
- 流式 SDK 不可用时：`asr_mode=window_fallback`，行为与第九轮一致。

**验收**：

- [ ] 正常配置 VOLC 时，日志主路径为 `asr_mode=stream`。
- [ ] 前端仍**不**默认展示完整转写（仅 debug 可看 partial）。
- [ ] 单测：mock 流式客户端，partial 多次触发 session 累积。

---

### 任务 Ob · P2-12 商业 OCR / 画布出图识别

**目标**：在规则版 `/ocr/ink` 之外，支持**真实**手写识别路径（可接第三方 OCR API 或 on-device；V1 章节题库优先）。

**建议改动**：

- `HandCanvasController` 导出 step 区域 PNG（`RepaintBoundary` + `toImage`）
- `ocr.py` 增加 `mode: "rule" | "hwr"`；hwr 调商业 API（如火山/百度/math OCR，密钥走 `.env`）
- `live_lecture_service._enrichAndSendSnapshot`：优先 hwr，失败回落 rule

**验收**：

- [ ] 学生手写 `\sqrt{12}` 类步骤，hwr 路径 `confidence >= 0.5` 的比例在 Demo 题上可观测（允许部分失败回落 rule）。
- [ ] 失败不阻塞讲题；日志区分 `source=hwr|reference_step|template`。

---

### 任务 P · P2-2 精彩讲题回放（家长端 + 学生端）

**目标**：满足 `planV1.md` §6「精彩回放」——家长可查看孩子**讲题过程**（视频或等价过程回放）。

**数据模型**（`db.py`）：

- 新增 `LectureReplayRecord`：`sessionId`、`studentId`、`sectionId`、`questionId`、`audioPath` 或 `audioBase64Chunks`、`inkTimelineJson`、`turnsTimelineJson`、`durationMs`、`createdAt`。
- 不强制 H.264 转码：**过程回放播放器**为验收底线；若实现 MP4 合成则加分。

**录制**（讲题页 / live session 结束）：

- 音频：聚合 session 的 PCM → 存 wav/mp3（服务端 `upload` 或本地缓存后 sync）。
- 笔迹：ink 事件带 `tMs` 时间戳序列。
- 对话：`turns` 带 `startMs` / `endMs`。

**播放**（新增 `replay_page.dart` + 家长端入口）：

- 时间轴：音频播放 + 画布按时间重放笔画 + 气泡高亮同步。
- 家长端：`/parent/replays` 列表 + 「观看回放」。

**验收**：

- [ ] 完成一次 live 讲题后，家长端可见该条回放。
- [ ] 播放时可看到笔迹逐步出现且与音频/气泡大致同步（误差 ≤500ms 可接受）。
- [ ] 无回放数据时显示温和空状态，不崩溃。

---

### 任务 Q · P2-3 费曼战力 + 段位徽章

**目标**：`planV1.md` §5.6.1 战力值 + 段位在个人主页展示。

**后端**：

- 表：`SectionPower`（studentId, sectionId, powerScore, rankTier）、`PowerEvent`（流水）。
- 公式（可简化但必须可解释）：`power = masteryScore * 10 + completedRounds * 5 + bountyWins * 15`；段位阈值：青铜 <300、白银 <600、黄金 <900、王者 ≥900（示例，写入代码常量）。
- API：`GET /gamification/me`、`POST /gamification/power/adjust`（内部由讲题完成/悬赏调用）。

**前端**：

- 首页或个人中心卡片：当前章节战力、段位图标、本周变化 ↑↓。
- 讲题页 AppBar 小徽章展示当前 section 战力。

**验收**：

- [ ] 完成讲题后战力上升；失败回合（masteryDelta≤0）不变或微降。
- [ ] 段位随战力跨阈值自动升级并 Toast/卡片提示。

---

### 任务 R · P2-4 地理排行榜（校 / 区 / 市 / 省）

**目标**：`planV1.md` §5.6.2 本地化排行榜 + 每周结算 + 称号装配。

**后端**：

- 表：`LeaderboardSnapshot`（scope: school|district|city|province、sectionId、weekId、rank、studentId、powerScore、titleLabel）。
- 学生资料扩展：`schoolName`、`province`、`city`、`district`（首次登录或设置页填写；定位 permission 可作辅助默认值）。
- API：`GET /leaderboard?sectionId=&scope=`；`GET /leaderboard/my-titles`。
- 周结算：cron 脚本 `scripts/settle_leaderboard.py` 或启动时补偿结算（文档说明）。

**前端**：

- 新页 `leaderboard_page.dart`：切换 校/区/市/省 Tab，展示 Top N + 自己名次。
- 称号装配到 `StudentProfile.equippedTitle`，讲题页/个人页展示。

**验收**：

- [ ] 至少 2 个测试账号同一学校可见校榜排名变化。
- [ ] 跨市数据隔离（不同 city 不进同一榜）。
- [ ] 周一 0 点结算后称号更新（可手工触发脚本演示）。

---

### 任务 S · P2-5 今日悬赏 · 挑错关卡

**目标**：`planV1.md` §5.6.3 每日 3 道易错题：圈错 + 语音纠错 + Agent 追问。

**内容**：

- 数据：`data/bounty/daily_YYYY-MM-DD.json` 或 DB 表 `BountyChallenge`（含错误解法 ink 模板、正确知识点 tags）。
- 首版至少为 **16 章**准备 9 套题（3 天轮转），能 Demo 即可扩展。

**玩法**：

1. 首页入口「今日悬赏」→ 展示错误解法画布（只读底图 + 可圈画红笔层）。
2. 学生圈选区域 → 与 `errorStepBoundingBox` IoU ≥ 阈值判「圈对」。
3. 开启麦克风 → 复用 **任务 O** 流式 ASR + **任务 A** 追问闭环。
4. 完成奖励：晶石 + 战力（任务 Q/T）。

**验收**：

- [ ] 圈错成功 + 语音说明后，发放晶石与战力流水。
- [ ] 未完成可次日刷新（日期切换）。

---

### 任务 T · P2-6 费曼晶石 + 虚拟商城

**目标**：晶石只能通过玩法获得；用于兑换虚拟商品（笔迹皮肤、头像框）。

**后端**：

- 表：`CrystalWallet`、`CrystalLedger`（amount、reason、refId）。
- 来源：讲题完成、bounty、排行榜结算；**禁止**充值接口。
- API：`GET /shop/catalog`、`POST /shop/redeem`（扣晶石、记流水）。

**前端**：

- `shop_page.dart`：商品列表、余额、兑换确认。
- 讲题白板应用已兑换的 `penStyle` / 头像框（至少 2 款可切换）。

**验收**：

- [ ] 晶石收支可追溯；余额不为负。
- [ ] 兑换后皮肤在讲题页可见变化。

---

### 任务 U · P2-7 极客学习工具局 · 实物兑换申请流

**目标**：`planV1.md` §5.6.5 用晶石兑换实物/工具——**无真实支付、无真实物流 API**，但必须有完整「下单申请」产品流。

**后端**：

- 表：`RedeemOrder`（skuId、studentId、status: pending|approved|shipped|completed、crystalCost、addressJson、createdAt）。
- SKU 静态配置：`data/shop/geek_skus.json`（圆规、错题打印机、番茄钟、错题本等）。

**前端**：

- 商城分栏「学习工具局」：SKU 详情、晶石价格、填写收货信息、提交申请。
- 学生「我的兑换」列表看状态；家长端可查看孩子申请（只读）。

**验收**：

- [ ] 提交后扣晶石、生成 pending 订单。
- [ ] 管理端或脚本可将状态改为 shipped（Mock 即可）。

---

### 任务 V · P2-8 拍照识题 + 知识点归属

**目标**：`planV1.md` §5.2 拍照上传 → 识别所属知识点 → 推送讲题。

**后端**：

- `POST /questions/upload-image`：multipart 图片。
- 识别：Kimi vision 或 OCR + LLM 分类到 `sectionId` / 知识点 tag（16 章优先）；返回 `questionPrompt` 草稿 + `confidence`。

**前端**：

- 首页「拍照识题」→ 相机/相册 → 确认知识点 → 进入 `LecturePage`（可新建临时 `questionId`）。

**验收**：

- [ ] 上传二次根式题图，推荐到 16.x 某一节。
- [ ] 识别失败时温和提示，可手动选章节。

---

### 任务 W · P2-9 课本向量检索 + Agent Tool

**目标**：`planV1.md` §5.2 向量化索引 + Agent 检索工具（先 **第十六章** 全节课文/知识点摘要）。

**后端**：

- `data/knowledge/pep-g8-down-ch16_chunks.json` + 启动时加载 embeddings（可用 sqlite-vec / 内存 cosine；或 Moonshot embedding API）。
- `POST /knowledge/search`：`query` → topK 片段。
- `lecture_agent` system prompt 注入检索结果；或 `tools/knowledge_search` 供 LLM 调用。

**验收**：

- [ ] 讲题时日志可见 `knowledge_hits=3`。
- [ ] 追问引用的规则与检索片段一致（肉眼可核对 Demo）。

---

### 任务 X · P2-10 全册章节题库扩展

**目标**：打破「仅 16 章有题」——`pep-junior-math.json` 中 **90 节**每节至少 **1 道** `available` 或 `comingSoon` 明确区分；可练习节必须 `available` + ≥1 题。

**实施**：

- 脚本 `scripts/generate_section_questions.py`：为每节生成 1～3 道模板题（按章节标题），写入 `data/questions/pep-junior-math-questions.json` 或扩展现有 mock repo。
- Flutter `MockLectureRepository` / 后端 `GET /questions?sectionId=` 统一读该文件。
- 未精细化教研的章节题面标「教研中」quality=stub，但**必须能进入讲题页完成闭环**（可用简化 Mock LLM）。

**验收**：

- [ ] 随机抽 5 个非 16 章节目录，可进入讲题页并提交/实时讲题。
- [ ] 首页题量徽标对该节显示 ≥1。

---

### 任务 Y · P2-11 多孩子 · 家长-子账号绑定

**目标**：家长账号可绑定多个学生；家长端切换孩子查看 dashboard/回放。

**后端**：

- 表：`ParentStudentLink`（parentUserId、studentProfileId、nickname）。
- 家长 API 带 `?studentId=` 或 `X-Student-Id` header；JWT 含 `activeStudentId` 或查询参数切换。
- 学生数据隔离：所有 learning/parent/replay 查询按 **active student** 过滤。

**前端**：

- 家长端顶栏孩子切换器；绑定流程：输入学生账号 / 扫码 / 邀请码（V1 用「学生用户名 + 确认码」即可）。

**验收**：

- [ ] 家长绑定 2 个孩子后，切换 dashboard 数据不同。
- [ ] 学生 A 进度不泄露给学生 B 家长视图。

---

### 任务 AA · P2-13 掌握度驱动难度推荐

**目标**：`planV1.md` §5.3 掌握越好 → 题越难、追问越深。

**实现**：

- `MockLectureRepository.questionForSection(sectionId, preferredDifficulty)`：根据 `SectionProgress.masteryScore` 选 基础/巩固/挑战。
- 讲题页「下一题」优先推荐高于当前掌握度的难度；首页提示「建议挑战：xxx」。
- `lecture_agent`：`masteryScore` 注入 prompt（高掌握度要求更深追问）。

**验收**：

- [ ] 掌握度 <30 时默认基础题；>60 时默认巩固/挑战。
- [ ] 日志可见 `recommendedDifficulty` 与掌握度相关。

---

### 任务 M · P0-4 / P0-5 文档与部署

| 文件 | 内容 |
|------|------|
| `项目规划/planV1.md` | §「实现状态」表：**V1+V2 全部列明**（含游戏化、回放、流式 ASR、全册题库） |
| `docs/MAC_LOCAL_DEV.md` | 真机 Base URL；WS；**流式 ASR** 超时；nginx Upgrade |
| `deploy.sh` 或 `docs/DEPLOY.md` | 健康检查 + WS；回放文件存储路径；定时 leaderboard 脚本 |
| `README.md` | 第十一轮 = 全量收口；`requirements.txt`；新 API 列表 |
| `AGENTS.md` | 踩坑：流式 ASR、回放时间轴、排行榜周结算、晶石流水 |
| `.env.example` | VOLC 流式 ASR、OCR HWR、embedding、存储路径 |

---

### 任务 N · P0-6 测试与 Demo 验收

#### N1 · 后端测试（全部要有）

- `test_lecture_agent_stream.py`（A）
- `test_round11_endpoints.py` 或扩展 round10：profile、reviews、gamification、leaderboard、shop、replay、upload-image、knowledge/search
- `test_volc_asr_stream.py`（O，mock）
- `test_leaderboard_settle.py`（R）

#### N2 · Flutter 测试（全部要有且通过）

- `storage_namespace_test.dart`（B）
- `learning_sync_merge_test.dart`（G）
- `parent_dashboard_payload_test.dart`
- `gamification_power_test.dart`（Q）
- `leaderboard_models_test.dart`（R）
- `replay_timeline_test.dart`（P）
- 回归：progress/review/live_lecture 既有用例不回归失败

#### N3 · `DEMO_SCRIPT.md` 条目 13（V1 缺口收口）

标题：**第十一轮上 · 真流式 + 数据隔离 + 公式 + 礼貌打断**

演示要点（**全部**勾完）：

1. 登录 userA 完成 16.3 一题 → 首页 10/100 → sync。
2. logout → 注册 userB → 首页 **无** userA 进度。
3. userA 再 login → 本地进度仍在；家长端 dashboard 与 userA 一致。
4. 实时讲题：日志 `source=llm_stream`；thinking 后气泡 **逐字** 增长（非整段弹出）。
5. TTS：小明 vs 李老师（及另外 2 角色）音色可区分。
6. TTS 播放时连续说话 ≥0.3s → 220ms 淡出打断 + **角色**礼貌气泡。
7. 边写边静音 1.5s → **不**抢问（3s 内有笔画）；停说停写 2.5s → 断档提示；4s → AI 思考。
8. 回顾/家长端/讲题气泡公式 `flutter_math_fork` 渲染正常。
9. 家长端弱项 + 最近讲题 + 海报；改展示名后刷新可见。
10. 首次「开始讲题」出现隐私说明后再申请麦克风。
11. `--dart-define=DEBUG_OCR=1` 可见 step 的 source/confidence（Release 默认关闭）。
12. 后端 `pytest` 与 Flutter 单测在本机通过（写入 `ROUND11_VERIFICATION.md`）。

#### N4 · `DEMO_SCRIPT.md` 条目 14（V2 全量能力）

标题：**第十一轮下 · 流式 ASR + 回放 + 游戏化 + 悬赏商城 + 识题 + 全册题库**

演示要点（**全部**勾完）：

1. 流式 ASR：边讲边 internal 更新；日志 `asr_mode=stream`。
2. 家长端播放孩子最近一次讲题**过程回放**（音+笔迹+气泡）。
3. 个人页：战力、段位、装配称号。
4. 排行榜：校级 Top 列表，切换省/市 Tab。
5. 今日悬赏：圈出错题步骤 + 语音纠错拿晶石。
6. 晶石商城：兑换笔迹皮肤并回到讲题页验证。
7. 极客工具局：提交兑换申请，订单 pending。
8. 拍照识题：相册选图 → 归入 16.x → 开讲。
9. 知识检索：日志有 knowledge hits（可 curl `/knowledge/search`）。
10. 非 16 章节目录抽 1 节进入讲题并完成一轮。
11. 家长绑定 2 学生并切换 dashboard。
12. hwr OCR 路径日志 `source=hwr`（或 Demo 说明回落 rule 原因）。

#### N5 · 验收报告（提交物）

在 `docs/ROUND11_VERIFICATION.md` 新建（本轮 Agent 填）：

```markdown
## 环境
- 后端版本 / 提交 hash
- Flutter 设备（模拟器/真机）
- KIMI / VOLC 是否配置

## 结果
| 条目 | PASS/FAIL | 备注 |
...

## P0 / P1 / P2 对照表
| ID | PASS/FAIL | 备注 |
| P0-1 … P0-6 | | |
| P1-1 … P1-12 | | |
| P2-1 … P2-13 | | |

## Demo 13 / 14
| 条目 1～12（§13） | PASS/FAIL | |
| 条目 1～12（§14） | PASS/FAIL | |

## 未验证项及原因
（仅允许写外部依赖不可用，如缺 KIMI_KEY；**禁止**写 NOT_IMPLEMENTED / SKIPPED / 时间不够）
```

---

## 4. 实现注意事项（强制）

1. **契约**：请求/响应 camelCase 与 Pydantic `serialization_alias` 对齐（见 AGENTS.md 第二轮踩坑）。
2. **错误**：路由用 `HTTPException`；WS 用 event `warning`/`error`，不要 200 包 error JSON。
3. **实时主路径**：禁止默认展开文字讲解框；`LIVE_FALLBACK_TEXTINPUT` 仅 debug。
4. **性能**：讲题页左侧 ListView + 白板 `RepaintBoundary` 勿拆。
5. **提交**：每任务独立 commit；`git add` 仅本次文件；message 英文 `feat:` / `fix:` / `docs:`。
6. **依赖**：容器内 `pub get` 用清华/Flutter 中国镜像（见 AGENTS.md 第九轮）。

---

## 5. 建议执行顺序（A～Z 全部必做，仅排期无省略）

| 顺序 | 任务 | 依赖提示 |
|------|------|----------|
| 1 | C requirements | — |
| 2 | B 数据隔离 | — |
| 3 | A 真流式 LLM | — |
| 4 | O 流式 ASR | 与 A 可并行 |
| 5 | Ob 商业 OCR | — |
| 6 | D 公式 | — |
| 7 | E / F / L 实时体验 | D |
| 8 | G / I / J 学习同步 | B |
| 9 | H 隐私 | — |
| 10 | X 全册题库 | — |
| 11 | W 知识库 RAG | X 部分并行 |
| 12 | Q 战力段位 | G |
| 13 | T 晶石 | Q |
| 14 | S 今日悬赏 | O,A,T,Q |
| 15 | R 排行榜 | Q,Y |
| 16 | U 工具局订单 | T |
| 17 | V 拍照识题 | X |
| 18 | AA 难度推荐 | G,Q |
| 19 | P 讲题回放 | O,A |
| 20 | Y 多孩子 | G,P,R |
| 21 | M 文档 | 代码稳定后 |
| 22 | N 测试 + Demo 13/14 + 验收报告 | **全部**完成后 |

---

## 6. 完成后同步清单（全部必做）

- [ ] **任务 A～Z（含 Ob、AA）** 代码与测试均已提交。
- [ ] `README.md`：第十一轮 = **planV1 全量收口**（非仅 V1 缺口）。
- [ ] `DEMO_SCRIPT.md` 条目 **13 + 14**。
- [ ] `项目规划/planV1.md` 实现状态表：**无「V2 待做」残留**（仅 §1.6 极窄项标未做）。
- [ ] `AGENTS.md` 踩坑追加本轮。
- [ ] `docs/ROUND11_VERIFICATION.md`：**P0、P1、P2 全部 PASS**；Demo 13+14 全部 PASS。
- [ ] `requirements.txt` / `pubspec.lock` / 新 JSON 数据文件一并提交。

---

## 7. 反例对照（勿做成这样）

| ❌ 错误 | ✅ 正确 |
|--------|--------|
| 流式失败直接 500 红条 | fallback 切片 + `stream_fallback` 日志 |
| `git add -A` 带上他人改动 | 只 add 本轮文件 |
| 换账号手动清 prefs 全删 | namespace 切换，保留各用户数据 |
| 公式升级后回顾页仍用 `Text` | 统一 `FormulaText` |
| 为流式在前端展示 ASR 全文 | 仍默认隐藏转写 |
| 把游戏化/回放/流式 ASR 留到 V2 | **本轮必须实现** O～Y、Ob、AA |
| 只做 A～N 不做 O～Y | §3 **A～Z 全做** |
| 实物兑换只做 UI 壳 | U 必须有订单状态机 + 扣晶石 |
| 全册题库仍只有 16 章 | X 要求 90 节均有题 |
| 验收只填 P0/P1 | **P2 也必须 PASS** |

---

## 8. 参考代码锚点（便于 Agent 跳转）

| 主题 | 路径 |
|------|------|
| 模拟流式切片 | `main/app/services/live_lecture_session.py` → `_split_text_into_deltas` |
| 同步 LLM 非流式 | `main/app/services/lecture_agent.py` → `generate_lecture_turns` |
| 本地进度 key | `main/mobile/lib/services/progress_repository.dart` → `_storageKey` |
| 静音触发 | `main/mobile/lib/pages/lecture_page.dart` → `_onAudioPause` |
| 打断 | `lecture_page.dart` → `_maybeInterruptAi`；`live_lecture_service.dart` → `stopTts` |
| OCR 规则 | `main/app/routers/ocr.py` → `recognize_steps` |
| 家长 dashboard | `main/app/routers/parent.py`；`parent_dashboard_page.dart` |

---

**本轮结束标志（唯一口径）**：

1. §3 **任务 A～Z（含 Ob、AA）均已实现**，各有 commit/代码可查。
2. `ROUND11_VERIFICATION.md` 中 **P0、P1、P2 每一行 PASS**；**Demo 13 + 14** 全部 PASS。
3. 允许在报告中注明「某条用 fallback 验证」（如缺 VOLC 流式凭证用 window ASR），但**禁止** NOT_IMPLEMENTED / SKIPPED /「下轮再做」。
4. 仅 §1.6 所列（真实支付、真实物流 API、家长充值）可标为 N/A——**不得**把游戏化、回放、排行榜、悬赏、商城、识题、全册题库标为 N/A。
