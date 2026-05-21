# Mac 本地开发指南（平板预览）

> **适用场景**：Linux 云服务器跑 Python 后端；Mac 改 Flutter 代码；安卓平板 USB 连 Mac 看效果。  
> **在 Mac 上**：用 Cursor 打开本仓库根目录，把本文档和下方「复制给 Cursor」一起交给本地 Agent。

---

## 架构（先理解再动手）

```
┌─────────────┐   USB      ┌─────────┐   WiFi/4G   ┌──────────────────┐
│  安卓平板    │ ◀──────── │   Mac   │             │  Linux 云服务器   │
│  显示 App   │  flutter  │ 改代码   │ ──────────▶ │  Python API :8001 │
└─────────────┘   run     └─────────┘   HTTP      └──────────────────┘
```

- **Mac 必须跑的命令**：`flutter run`（装 App + 热重载到平板）
- **服务器必须有的**：后端已启动，且 `http://<服务器IP>:8001/health` 可访问
- **平板**：USB 调试已开启，Mac 上 `adb devices` 显示 `device`

---

## 复制给 Cursor（Mac 本地窗口粘贴这段）

把下面整段复制到 **Mac 上 Cursor 的新对话**里：

```text
请阅读仓库里的 docs/MAC_LOCAL_DEV.md，按顺序帮我在 Mac 上完成 Android 平板开发环境验证和首次 flutter run。

要求：
1. 先检查 flutter、adb 是否可用；不可用则给出 Mac 安装步骤
2. 运行 adb devices 和 flutter devices，帮我解读输出是否表示平板已连接成功
3. 在 main/mobile 执行 flutter pub get
4. 询问我的云服务器公网 IP（若我不知道，提示我用浏览器测 /health）
5. 用 run_dev.sh 或等价命令启动 flutter run，API 指向云服务器 :8001
6. 每步执行终端命令，根据输出决定下一步；出错时给排查清单

项目仓库路径：（在这里填你 Mac 上的路径，例如 ~/AI-Feynman）
云服务器 API 地址：（在这里填，例如 http://39.106.211.238:8001）
```

---

## 一次性准备（Mac）

### 1. 安装工具

```bash
# 若未安装 Homebrew：https://brew.sh
brew install --cask flutter android-studio

flutter doctor
flutter doctor --android-licenses   # 全部输入 y
```

`flutter doctor` 里 **Android toolchain** 不要有红色 ✗。

### 2. 克隆代码（若还没有）

```bash
cd ~
git clone https://github.com/sunimo-pku/AI-Feynman.git
cd AI-Feynman
```

用 Cursor：**File → Open Folder → 选择 `AI-Feynman` 文件夹**（选仓库根目录，不是 `main/mobile`）。

### 3. 确认云服务器后端

在 Mac **浏览器**打开（把 IP 换成你的）：

```
http://<服务器公网IP>:8001/health
```

应看到 JSON：`{"status":"ok",...}`

若打不开：在服务器执行 `bash deploy.sh`，并检查云厂商安全组是否放行 **8001** 端口。

---

## 每次开发（日常流程）

### 终端 1：确认平板已连接

```bash
adb devices
# 期望：一行 xxxxx    device

flutter devices
# 期望：列出你的平板 (mobile)
```

### 终端 2：启动 App 预览（在 Mac 上）

```bash
cd main/mobile
flutter pub get

# 方式 A：用脚本（推荐，先改脚本里的 IP）
./run_dev.sh

# 方式 B：手动指定 API
flutter run --dart-define=API_BASE_URL=http://<服务器公网IP>:8001
```

**首次编译约 3～10 分钟**，完成后平板会自动打开「AI 费曼」。

### 热重载（改代码时）

`flutter run` 保持运行，在 Cursor 里改 `main/mobile/lib/` 下的文件，保存后回到终端：

| 按键 | 作用 |
|------|------|
| `r` | 热重载（改 UI，秒级刷新） |
| `R` | 热重启 |
| `q` | 退出 |

### 怎么算成功

| 检查项 | 成功标志 |
|--------|----------|
| USB | `adb devices` → `device` |
| App 安装 | 平板自动打开「AI 费曼」 |
| 后端 | App 右上角 **「API 已连接」** |
| 热重载 | 改 `lib/` 代码按 `r`，平板界面变化 |

**「API 未连接」**：USB 没问题，是平板访问不到服务器——查 IP、8001 端口、后端是否运行。

---

## 配置 API 地址

编辑 `main/mobile/run_dev.sh` 里的 `API_BASE_URL`，改成你的服务器地址。

或在单次运行时覆盖：

```bash
API_BASE_URL=http://203.0.113.1:8001 ./run_dev.sh
```

---

## 常见问题

### `adb: command not found`

Android Studio → Settings → Android SDK → SDK Tools → 勾选 **Android SDK Platform-Tools**。

Mac 终端执行（路径按 Android Studio 默认）：

```bash
export PATH="$PATH:$HOME/Library/Android/sdk/platform-tools"
```

可写入 `~/.zshrc` 永久生效。

### `adb devices` 显示 `unauthorized`

平板上点「允许 USB 调试」；勾选「始终允许」。

### `adb devices` 为空

- 换一根**能传数据**的线（不要只用充电线）
- 平板通知栏 USB 模式选 **文件传输 / MTP**
- 重新插拔

### 开发者选项 / 没有「版本号」

设置 → **关于平板电脑 / 关于设备** → 连续点 7 次：

- **编译编号** / **Build 号** / **MIUI 版本** / **内部版本号**（品牌不同名字不同）

然后：设置 → **开发者选项** → 打开 **USB 调试**。

### 不想用 USB

见本文档末尾「附录：无线调试」；新手建议先用 USB。

---

## 和后端分工

| 改什么 | 在哪改 | 怎么生效 |
|--------|--------|----------|
| App 界面、交互 | Mac · `main/mobile/lib/` | 终端按 `r` 热重载 |
| API、LLM、数据库 | 云服务器 · `main/app/` | SSH 后 `bash deploy.sh` |
| 课程目录 JSON | `data/curriculum/` | 服务器跑 `python scripts/build_curriculum.py`，Mac `git pull` 后重启 App |

---

## 第十一轮实时能力调试

- 真机 Base URL：Android 模拟器可继续用 `http://10.0.2.2:8001`；真机必须用局域网 IP：

```bash
flutter run --dart-define=API_BASE_URL=http://<你的电脑IP>:8001
```

- DEBUG_OCR 面板：讲题页默认不展示 OCR 细节；调试 HWR 时使用：

```bash
flutter run \
  --dart-define=API_BASE_URL=http://<你的电脑IP>:8001 \
  --dart-define=DEBUG_OCR=1
```

- 拍照识题：第十二轮引入 `image_picker`，Android 真机首次访问相册/相机时会触发系统权限。若权限被拒绝，需要到系统设置中允许「照片和视频」/「相机」。
- Qwen-VL 视觉识题：在 `.env` 配置 `ALIYUN_API_KEY` 后，`/questions/upload-image` 会调用阿里云 DashScope OpenAI 兼容接口（默认模型 `qwen-vl-plus`）；失败时返回 502。
- WebSocket：`/lecture/live` 需要 nginx 透传 Upgrade 头；本地直连时确认 `ws://<IP>:8001/lecture/live` 可建立连接。
- 流式 ASR：实时讲题必须配置 `VOLC_ASR_STREAM_*`。完全未配置时前端应收到明确错误，不再降级成窗口式 ASR。
- OCR/HWR：接 HWR 供应商时配置 `OCR_HWR_API_KEY`。未配置任何 HWR key 时，有 `referenceSteps` 才返回 `reference_step`，否则返回空识别结果。
- 回放：结构化时间轴通过 `/replays` 保存，服务端默认存数据库 JSON；如后续落文件，路径用 `.env` 的 `REPLAY_STORAGE_DIR`。当前 App 端在 `ReplayService` 内临时缓存本次 live 的音频 chunk、白板 timeline 与气泡 timeline，完成或退出时尽力上传。

nginx 反代示例：

```nginx
location /lecture/live {
    proxy_pass http://127.0.0.1:8001;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 360s;
    proxy_send_timeout 360s;
}
```

LLM、ASR、OCR 都可能超过默认 60s，生产反代建议把 `proxy_read_timeout` 拉长到 300s 以上。

---

## 附录：无线调试（可选，Android 11+）

1. 先用 USB 连一次，或平板开发者选项里打开「无线调试」
2. Mac 与平板**同一 WiFi**
3. 平板「无线调试」里点「使用配对码配对设备」，Mac 执行：

```bash
adb pair <平板IP>:<配对端口>    # 输入配对码
adb connect <平板IP>:<连接端口>
flutter devices
```

之后可拔 USB，继续 `flutter run`。

---

## 附录：不用 USB、只装 APK（无热重载）

```bash
cd main/mobile
flutter build apk --release
```

APK 路径：`build/app/outputs/flutter-apk/app-release.apk`  
传到平板安装。每改一次代码都要重新 build + 安装，**不适合日常开发**。
