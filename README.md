# AI 费曼（AI-Feynman）

面向**初中数学**的定制化「费曼学习法」App（平板端）。学生通过手写 + 语音向多个 AI 角色讲题，系统追踪掌握度；家长端查看弱项与学习回放。

> 详细产品规划见 [`项目规划/planV1.md`](./项目规划/planV1.md)

## 仓库

[github.com/sunimo-pku/AI-Feynman](https://github.com/sunimo-pku/AI-Feynman)

## 目录结构

```
.
├── README.md
├── AGENTS.md                 # AI 协作规范（Agent 修改前必读）
├── FRONTEND_STYLE.md         # 前端视觉与交互规范
├── DEMO_SCRIPT.md            # Demo 演示提纲（随功能追加）
├── deploy.sh                 # 一键部署
├── .env.example              # 环境变量模板（复制为 .env 后填写）
├── 项目规划/
│   └── planV1.md             # 产品规划 V1
├── data/
│   └── curriculum/
│       └── pep-junior-math.json   # 人教版初中数学目录（6 册 · 29 章 · 90 节）
├── scripts/
│   └── build_curriculum.py   # 重新生成课程目录 JSON
└── main/
    ├── app/                  # 后端
    └── frontend/             # 前端
        └── src/data/         # 课程目录读取与类型定义
```

## 核心设计原则

| 原则 | 说明 |
|------|------|
| 目录做全 | 人教版初一～初三完整章节树，用户可浏览全貌 |
| 内容先填一块 | V1 仅一个小章节有题目、讲题流程与掌握度 |
| 快速迭代 | 先做可验证原型，找真实用户反馈后再改 |
| 做深做窄 | 一个完整闭环 > 多个半成品功能 |

## 文档索引

| 文件 | 用途 |
|------|------|
| `项目规划/planV1.md` | 目标用户、交互模式、学生端/家长端功能、V1 边界 |
| `data/curriculum/pep-junior-math.json` | APP 章节选择数据源 |
| `AGENTS.md` | Git 规范、踩坑记录、Agent 强制规则 |
| `FRONTEND_STYLE.md` | 新建/重构页面时必须遵循的视觉规范 |

## 环境配置

敏感信息写入根目录 `.env`（已加入 `.gitignore`），参考 `.env.example` 填写。**切勿提交 `.env`。**

## 部署

```bash
bash deploy.sh
```

默认本机健康检查地址：`http://127.0.0.1:8001/health`
