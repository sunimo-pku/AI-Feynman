# 前端风格规范（FRONTEND_STYLE.md）

> **核心定位**：专业、优雅、精致的 AI 面试空间。
> **优先级**：本文件高于一切临时审美判断。任何新建、重构、优化前端页面/组件/样式/动画/交互前，**必须先读完本文件**。

---

## 1. 核心美学：Clean & Elegant Interview Space

**一句话定调**：
> 这是一个让人专注、平静、感受到专业与信任的面试空间。它应该像一个光线充足、布置讲究的现代办公室，而不是一个充满警告灯的黑客控制台。

**关键词**：
**追求**：优雅、克制、呼吸感、柔和圆角、弥散阴影、现代无衬线体、知性色彩。
**远离**：赛博朋克、复古控制台、硬核边框、全屏噪点、等宽字体泛滥、高饱和度警告色。

---

## 2. Aesthetic Guidelines（核心视觉要素）

### 2.1 Typography（字体排版）

| 角色 | 字体 | 用途 |
| --- | --- | --- |
| **Display (标题)** | `Inter`, `PingFang SC`, sans-serif | 页面大标题、Logo、核心模块名称 |
| **Body (正文)** | `Inter`, `PingFang SC`, sans-serif | 对话气泡、按钮文字、说明文本、表单 |
| **Mono (等宽)** | `JetBrains Mono`, monospace | 仅用于：代码块、精确计时器、数字统计 |

**排版铁律**：
- **增加呼吸感**：正文行高使用 `leading-relaxed` (1.625) 或 `leading-loose`。
- **克制的大写**：不要滥用全大写和超大字间距。模块标题可以是正常大小写，配合微弱的 `tracking-wide`。
- **层级分明**：通过字号和颜色深浅（而不是夸张的字体切换）来区分信息层级。

### 2.2 Color & Theme（色彩体系）

**主色调**：知性蓝 (Sapphire) 或 翡翠青 (Teal)，传递信任与专业。

```css
@theme {
  --brand-hue: 220; /* 偏蓝灰的中性冷色调 */

  /* 亮色模式（默认，清爽干净） */
  --color-bg:        oklch(0.98 0.005 var(--brand-hue));
  --color-elevated:  oklch(1 0 0); /* 纯白卡片 */
  --color-overlay:   oklch(0.98 0.005 var(--brand-hue) / 0.8);
  --color-border:    oklch(0.90 0.01 var(--brand-hue));
  --color-grid:      oklch(0.95 0.01 var(--brand-hue));

  /* 文本层级 */
  --color-fg:        oklch(0.20 0.02 var(--brand-hue));
  --color-fg-muted:  oklch(0.45 0.02 var(--brand-hue));
  --color-fg-subtle: oklch(0.60 0.02 var(--brand-hue));

  /* 强调色：知性蓝 */
  --color-accent:        oklch(0.55 0.15 250);
  --color-accent-soft:   oklch(0.55 0.15 250 / 0.1);
  --color-accent-strong: oklch(0.45 0.15 250);
  
  /* 状态色 */
  --color-signal:        oklch(0.65 0.15 160); /* 柔和的成功绿 */
  --color-warn:          oklch(0.75 0.15 80);
  --color-error:         oklch(0.60 0.15 25);
}

/* 暗色模式覆盖（深邃专注） */
html[data-theme="dark"] {
  --color-bg:        oklch(0.18 0.01 var(--brand-hue));
  --color-elevated:  oklch(0.22 0.015 var(--brand-hue));
  --color-overlay:   oklch(0.18 0.01 var(--brand-hue) / 0.8);
  --color-border:    oklch(0.30 0.01 var(--brand-hue));
  
  --color-fg:        oklch(0.95 0.01 var(--brand-hue));
  --color-fg-muted:  oklch(0.70 0.01 var(--brand-hue));
  --color-fg-subtle: oklch(0.55 0.01 var(--brand-hue));

  --color-accent:        oklch(0.70 0.15 250);
  --color-accent-soft:   oklch(0.70 0.15 250 / 0.15);
  --color-accent-strong: oklch(0.80 0.15 250);
}
```

### 2.3 Shapes & Elevation（形态与深度）

- **圆角 (Radius)**：告别尖锐。
  - 按钮/小元素：`8px` (`rounded-md` 或 `rounded-lg`)
  - 卡片/模块：`12px` 或 `16px` (`rounded-xl` 或 `rounded-2xl`)
  - 对话气泡：`16px` (`rounded-2xl`)
- **阴影 (Shadows)**：引入柔和的弥散阴影，增加界面的层次感。
  - 卡片默认：极淡的底层阴影 `shadow-sm` 或 `shadow-[0_2px_8px_oklch(0_0_0/0.04)]`。
  - 悬浮/弹窗：`shadow-lg` 配合毛玻璃效果 `backdrop-blur-md`。
- **边框 (Borders)**：边框颜色要极度微弱，仅作为视觉辅助，不要形成强烈的“画框感”。

### 2.4 Motion（动效）

- **平滑过渡**：所有颜色切换、Hover 状态、展开折叠都应包含 `transition-all duration-200 ease-out`。
- **优雅入场**：页面加载和弹窗出现时，使用轻微的向上浮出和渐显（`translate-y-2 opacity-0` -> `translate-y-0 opacity-100`）。

---

## 3. 核心组件规范

### 3.1 顶栏 (TopBar)
- 移除硬核的边框线，使用极淡的底边框或轻微的阴影。
- 背景可采用半透明毛玻璃 (`bg-bg/80 backdrop-blur-md`)。
- 移除所有类似 `[ MODULE ]` 的方括号装饰。

### 3.2 模块卡片 (ModuleCard / Card)
- 增加圆角至 `12px` (`rounded-xl`)。
- 移除卡片头部的强割裂感边框，标题区域留白增加。
- 标题使用无衬线字体，字号适中，颜色柔和。

### 3.3 按钮 (Button)
- 默认圆角 `8px` (`rounded-lg`)。
- 主按钮 (Solid)：使用知性蓝背景，文字纯白，Hover 时轻微提亮并增加淡阴影。
- 次按钮 (Outline/Ghost)：移除生硬的边框，Hover 时背景变为极淡的强调色。

### 3.4 对话区域 (Chat Area)
- **恢复气泡布局**：面试官（AI）和候选人（User）的对话需要清晰的视觉区分。
  - AI 气泡：居左，背景色为 `bg-elevated`，带微弱阴影。
  - 用户气泡：居右，背景色为 `bg-accent`，文字纯白。
- 气泡圆角 `16px`，可以根据对话连续性调整单侧圆角（例如连续对话时，相邻侧圆角变小）。
- 移除终端风格的 `└─` 符号和时间戳前缀。

### 3.5 输入区 (Input Area)
- 整体作为一个圆润的胶囊或大圆角矩形 (`rounded-2xl`)。
- 麦克风按钮：圆形或大圆角，使用强调色。
- 发送按钮：优雅的图标按钮，无硬核描边。

---

## 4. Anti-Slop (反面模式)

**严禁出现以下“复古硬核”元素**：
1. ❌ 全屏噪点 (`GrainOverlay`)
2. ❌ 扫描线 (`.scanlines`)
3. ❌ 大面积使用 `JetBrains Mono` 或 `Major Mono Display` 作为 UI 标题。
4. ❌ 终端风格的方括号标签 `[ MODULE.NAME ]`。
5. ❌ 纯平面的 1px 强对比边框，无任何圆角或阴影。
6. ❌ 琥珀色/橙色作为主界面强调色（除非是真正的警告状态）。

---

## 5. 交付标准
- 界面看起来像一个现代的 SaaS 产品或高级效率工具（如 Notion, Linear 的柔和版）。
- 视觉重心始终在“对话内容”和“面试者状态”上，而不是 UI 框架本身。