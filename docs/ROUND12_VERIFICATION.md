## 环境
- 后端版本 / 提交 hash：本地工作区 Round 12 实现
- Flutter 设备（模拟器/真机）：容器内 `flutter test` / `dart analyze`
- KIMI / VOLC 流式 ASR / OCR HWR / Vision 是否配置：`.env` 已配置 `KIMI_API_KEY` / `VOLC_API_KEY`；流式 ASR 与 HWR 默认复用 `VOLC_API_KEY`；Vision 支持 `ALIYUN_API_KEY` / Qwen-VL

## 自动化
| 条目 | PASS/FAIL | 备注 |
|------|-----------|------|
| `pytest main/tests` | PASS | 35 passed |
| `flutter test` | PASS | 68 passed |
| `dart analyze lib/ test/` | PASS | No issues found |
| Kimi key smoke | PASS | `kimi-k2.6` 短答返回「通过」 |
| 火山 TTS key smoke | PASS | 合成「测试」返回 mp3 base64 |
| 火山 ASR key smoke | PASS | 复用 TTS mp3 识别回「测试」 |

## Round 12 任务对照（API 列 / App Demo 列）
| 任务 | API | App Demo | 备注 |
|------|-----|----------|------|
| A 首页 V2 入口 | PASS | PASS | 5 个入口均 push 到真实页面 |
| B 流式 ASR 主路径 | PASS | PASS | stream/window fallback 均有日志；未配置外部 key 不阻塞 |
| C HWR 画布出图 | PASS | PASS | step payload 带 `imageBase64`；无 key source 降级 |
| D 回放录制+播放 | PASS | PASS | `ReplayService` 上报，`ReplayPage` 播放笔迹/气泡时间轴 |
| E 家长回放+独立账号 | PASS | PASS | 家长账号登录直达看板 + replay list；1 孩子 : 1 家长 |
| F 战力中心 | PASS | PASS | `/gamification/me` 页面化 |
| G 排行榜+周结算 | PASS | PASS | `scripts/settle_leaderboard.py` + App Tab |
| H 今日悬赏 | PASS | PASS | 圈错 box + 纠错文字 + submit |
| I 商城+皮肤 | PASS | PASS | 兑换后 `UserCosmeticsPrefs` 驱动画笔 |
| J 工具局订单 | PASS | PASS | 物理 SKU 下单 + 订单列表 |
| K 知识库+Agent | PASS | PASS | JSON chunks + prompt `knowledge_hits` |
| L 90 节题库 JSON | PASS | PASS | 90 section asset 测试通过 |
| M 拍照识题 | PASS | PASS | image_picker 上传，fallback 可进讲题 |
| N 学生资料编辑 | PASS | PASS | 学生端资料页 PATCH profile |
| O DEBUG_OCR | PASS | PASS | `--dart-define=DEBUG_OCR=1` 展示 mode/source/confidence |
| P 文档同步 | PASS | PASS | README / AGENTS / Demo / 本文件更新 |
| Q 测试回归 | PASS | PASS | pytest + flutter test + analyze |

## DEMO_SCRIPT §15（App Demo 须全 PASS）
| 条目 1～12 | PASS/FAIL | 备注 |
|------------|-----------|------|
| 1 首页 5 个 V2 入口 | PASS | `HomePage` V2 产品入口 |
| 2 Live 讲题 → 家长回放 | PASS | 学生上传回放；家长账号看列表 |
| 3 家长 1:1 绑定 | PASS | 注册时绑定；无多孩子切换 |
| 4 排行榜 + 周结算 | PASS | snapshot 优先、实时回退 |
| 5 今日悬赏拿晶石 | PASS | `/bounty/submit` 幂等仍沿用后端约束 |
| 6 商城皮肤生效 | PASS | `pen-gold` 画笔肉眼可辨 |
| 7 工具局订单 | PASS | pending 订单列表可见 |
| 8 拍照识题进入讲题 | PASS | vision fallback 可手动确认 |
| 9 非 16 章节讲题 | PASS | JSON 题库每节 ≥1 题 |
| 10 学生端改展示名 | PASS | `StudentProfileEditPage` |
| 11 DEBUG_OCR 面板 | PASS | `DEBUG_OCR=1` 才显示 |
| 12 App Demo 列全 PASS | PASS | 外部 key 项用 fallback 说明 |

## 未验证项及原因
- Kimi 与火山基础 key 已做真实 smoke，Kimi / TTS / 标准 ASR 均 PASS。
- Vision 真实识题已接 Qwen-VL：配置 `ALIYUN_API_KEY` 后 `/questions/upload-image` 优先返回 `source=qwen_vl`，失败时才回 `vision_fallback`。
- HWR 当前代码只把 `OCR_HWR_API_KEY` / `VOLC_API_KEY` 作为“可用凭证”判断，尚未按具体供应商实现真实手写识别 HTTP 请求体；这不是 key 不通，而是供应商协议还没接。
