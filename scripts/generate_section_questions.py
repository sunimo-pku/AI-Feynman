#!/usr/bin/env python3
"""Generate a junior-math seed question bank from the curriculum tree.

The generated bank gives every section three questions: 基础 / 巩固 / 挑战.
Questions are intentionally original seed content, not copied from textbooks.
Visual-heavy topics receive a simple SVG diagram asset referenced by JSON.
"""

from __future__ import annotations

import json
import re
import shutil
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CURRICULUM = ROOT / "data" / "curriculum" / "pep-junior-math.json"
DATA_OUT = ROOT / "data" / "questions" / "pep-junior-math-questions.json"
MOBILE_OUT = (
    ROOT / "main" / "mobile" / "assets" / "questions" / "pep-junior-math-questions.json"
)
DATA_DIAGRAMS = ROOT / "data" / "questions" / "diagrams"
MOBILE_DIAGRAMS = ROOT / "main" / "mobile" / "assets" / "questions" / "diagrams"

DIFFICULTY_LABELS = {1: "基础", 2: "巩固", 3: "挑战"}

CH16_QUESTIONS: dict[str, list[dict[str, Any]]] = {
    "pep-g8-down-s16-1": [
        {
            "questionId": "q-s16-1-001",
            "prompt": r"判断 $\sqrt{2x-6}$ 在实数范围内有意义时，$x$ 的取值范围。",
            "hint": "提示：被开方数必须非负。",
            "referenceSteps": [r"$2x - 6 \ge 0$", r"$x \ge 3$"],
            "difficulty": 1,
            "tags": ["取值范围", "非负条件"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-1-002",
            "prompt": r"判断 $\sqrt{5-x}$ 在实数范围内有意义时，$x$ 的取值范围。",
            "hint": r"提示：把不等式 $5 - x \ge 0$ 化简后再写结论。",
            "referenceSteps": [r"$5 - x \ge 0$", r"$x \le 5$"],
            "difficulty": 2,
            "tags": ["取值范围", "移项"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-1-003",
            "prompt": r"判断 $\sqrt{x+3} + \sqrt{2-x}$ 在实数范围内有意义时，$x$ 的取值范围。",
            "hint": r"提示：两个被开方数都要 $\ge 0$，最终取交集。",
            "referenceSteps": [
                r"$x + 3 \ge 0 \Rightarrow x \ge -3$",
                r"$2 - x \ge 0 \Rightarrow x \le 2$",
                r"$-3 \le x \le 2$",
            ],
            "difficulty": 3,
            "tags": ["公共定义域", "不等式组"],
            "quality": "curated",
        },
    ],
    "pep-g8-down-s16-2": [
        {
            "questionId": "q-s16-2-001",
            "prompt": r"化简：$\sqrt{12} \cdot \sqrt{3}$，并说明用到的乘法法则与前提条件。",
            "hint": r"提示：$\sqrt{a} \cdot \sqrt{b} = \sqrt{ab}$（$a, b \ge 0$）。",
            "referenceSteps": [r"$\sqrt{12 \cdot 3}$", r"$\sqrt{36}$", r"$= 6$"],
            "difficulty": 1,
            "tags": ["乘法法则", "前提条件"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-2-002",
            "prompt": r"化简：$\sqrt{50} \div \sqrt{2}$。",
            "hint": r"提示：$\dfrac{\sqrt{a}}{\sqrt{b}} = \sqrt{\dfrac{a}{b}}$（$a \ge 0, b > 0$）。",
            "referenceSteps": [r"$\sqrt{50 \div 2}$", r"$\sqrt{25}$", r"$= 5$"],
            "difficulty": 2,
            "tags": ["除法法则", "化简"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-2-003",
            "prompt": r"化简：$\sqrt{8} \cdot \sqrt{18}$。",
            "hint": "提示：先用乘法法则合并，再把完全平方数全部提出来。",
            "referenceSteps": [r"$\sqrt{8 \cdot 18}$", r"$\sqrt{144}$", r"$= 12$"],
            "difficulty": 3,
            "tags": ["乘法", "完全平方数"],
            "quality": "curated",
        },
    ],
    "pep-g8-down-s16-3": [
        {
            "questionId": "q-s16-3-001",
            "prompt": r"化简：$\sqrt{12} - \sqrt{27}$。",
            "hint": "提示：先化为最简二次根式，再合并同类二次根式。",
            "referenceSteps": [
                r"$\sqrt{12} = 2\sqrt{3}$",
                r"$\sqrt{27} = 3\sqrt{3}$",
                r"$2\sqrt{3} - 3\sqrt{3} = -\sqrt{3}$",
            ],
            "difficulty": 1,
            "tags": ["最简二次根式", "同类二次根式"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-3-002",
            "prompt": r"化简：$2\sqrt{8} + \sqrt{18}$。",
            "hint": r"提示：先把 $\sqrt{8}$、$\sqrt{18}$ 化成同底再合并。",
            "referenceSteps": [
                r"$2\sqrt{8} = 4\sqrt{2}$",
                r"$\sqrt{18} = 3\sqrt{2}$",
                r"$4\sqrt{2} + 3\sqrt{2} = 7\sqrt{2}$",
            ],
            "difficulty": 2,
            "tags": ["化简", "合并同类项"],
            "quality": "curated",
        },
        {
            "questionId": "q-s16-3-003",
            "prompt": r"化简：$\sqrt{45} - 2\sqrt{20} + \sqrt{5}$。",
            "hint": r"提示：三项都化成同底 $\sqrt{5}$，再依次合并系数，留意负号。",
            "referenceSteps": [
                r"$\sqrt{45} = 3\sqrt{5}$",
                r"$2\sqrt{20} = 4\sqrt{5}$",
                r"$3\sqrt{5} - 4\sqrt{5} + \sqrt{5} = 0$",
            ],
            "difficulty": 3,
            "tags": ["多项合并", "负号"],
            "quality": "curated",
        },
    ],
}


def _safe_slug(text: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", text.lower()).strip("-")


def _topic_kind(title: str) -> str:
    if any(k in title for k in ["统计", "直方图", "数据", "抽样", "节水"]):
        return "statistics"
    if "概率" in title:
        return "probability"
    if any(k in title for k in ["函数", "坐标"]):
        return "function"
    if any(k in title for k in ["方程", "方程组"]):
        return "equation"
    if "不等式" in title:
        return "inequality"
    if any(k in title for k in ["二次根式", "平方根", "立方根", "实数"]):
        return "radical"
    if any(k in title for k in ["整式", "因式分解", "分式"]):
        return "algebra"
    if any(
        k in title
        for k in [
            "几何",
            "直线",
            "射线",
            "线段",
            "角",
            "相交线",
            "平行线",
            "平移",
            "三角形",
            "全等",
            "轴对称",
            "勾股",
            "四边形",
            "平行四边形",
            "矩形",
            "菱形",
            "正方形",
            "旋转",
            "圆",
            "相似",
            "投影",
            "视图",
        ]
    ):
        return "geometry"
    return "concept"


def _tags(title: str, kind: str) -> list[str]:
    base = {
        "statistics": ["数据", "读图", "表达"],
        "probability": ["概率", "样本空间", "表达"],
        "function": ["函数", "图像", "关系"],
        "equation": ["方程", "建模", "检验"],
        "inequality": ["不等式", "解集", "数轴"],
        "radical": ["概念", "运算", "条件"],
        "algebra": ["代数式", "化简", "运算"],
        "geometry": ["几何图形", "推理", "标注"],
        "concept": ["概念", "例子", "易错点"],
    }[kind]
    keyword = re.sub(r"[()（）一二三四五六七八九十0-9.·—\-]", "", title).strip()
    return ([keyword[:6]] if keyword else []) + base[:2]


def _svg(kind: str, title: str) -> str:
    if kind == "statistics":
        return """<svg xmlns="http://www.w3.org/2000/svg" width="420" height="220" viewBox="0 0 420 220">
  <rect width="420" height="220" rx="18" fill="#FBFBFA"/>
  <line x1="52" y1="178" x2="380" y2="178" stroke="#334155" stroke-width="2"/>
  <line x1="52" y1="178" x2="52" y2="34" stroke="#334155" stroke-width="2"/>
  <rect x="86" y="118" width="46" height="60" fill="#93C5FD"/>
  <rect x="166" y="78" width="46" height="100" fill="#67E8F9"/>
  <rect x="246" y="48" width="46" height="130" fill="#38BDF8"/>
  <text x="92" y="200" font-size="16" fill="#0F172A">甲</text>
  <text x="172" y="200" font-size="16" fill="#0F172A">乙</text>
  <text x="252" y="200" font-size="16" fill="#0F172A">丙</text>
  <text x="312" y="64" font-size="15" fill="#1E40AF">读出最高项</text>
</svg>
"""
    if kind == "function":
        return """<svg xmlns="http://www.w3.org/2000/svg" width="420" height="220" viewBox="0 0 420 220">
  <rect width="420" height="220" rx="18" fill="#FBFBFA"/>
  <line x1="40" y1="170" x2="382" y2="170" stroke="#334155" stroke-width="2"/>
  <line x1="84" y1="188" x2="84" y2="26" stroke="#334155" stroke-width="2"/>
  <polyline points="84,150 150,118 220,84 300,46" fill="none" stroke="#0891B2" stroke-width="4"/>
  <circle cx="150" cy="118" r="5" fill="#1E40AF"/>
  <circle cx="220" cy="84" r="5" fill="#1E40AF"/>
  <text x="312" y="48" font-size="16" fill="#1E40AF">y 随 x 增大</text>
  <text x="356" y="164" font-size="16" fill="#0F172A">x</text>
  <text x="92" y="42" font-size="16" fill="#0F172A">y</text>
</svg>
"""
    if kind == "probability":
        return """<svg xmlns="http://www.w3.org/2000/svg" width="420" height="220" viewBox="0 0 420 220">
  <rect width="420" height="220" rx="18" fill="#FBFBFA"/>
  <circle cx="130" cy="110" r="46" fill="#DBEAFE" stroke="#1E40AF" stroke-width="3"/>
  <circle cx="210" cy="110" r="46" fill="#CFFAFE" stroke="#0891B2" stroke-width="3"/>
  <circle cx="290" cy="110" r="46" fill="#FEE2E2" stroke="#EF4444" stroke-width="3"/>
  <text x="119" y="116" font-size="18" fill="#0F172A">红</text>
  <text x="199" y="116" font-size="18" fill="#0F172A">蓝</text>
  <text x="279" y="116" font-size="18" fill="#0F172A">白</text>
  <text x="120" y="180" font-size="16" fill="#1E40AF">摸到指定颜色的概率</text>
</svg>
"""
    return """<svg xmlns="http://www.w3.org/2000/svg" width="420" height="220" viewBox="0 0 420 220">
  <rect width="420" height="220" rx="18" fill="#FBFBFA"/>
  <polygon points="96,164 198,50 324,164" fill="#DBEAFE" stroke="#1E40AF" stroke-width="3"/>
  <line x1="198" y1="50" x2="198" y2="164" stroke="#0891B2" stroke-width="3" stroke-dasharray="6 5"/>
  <path d="M178 164 L178 144 L198 144" fill="none" stroke="#EF4444" stroke-width="3"/>
  <text x="86" y="184" font-size="16" fill="#0F172A">A</text>
  <text x="192" y="42" font-size="16" fill="#0F172A">B</text>
  <text x="326" y="184" font-size="16" fill="#0F172A">C</text>
  <text x="218" y="108" font-size="15" fill="#1E40AF">根据图形说明理由</text>
</svg>
"""


def _needs_diagram(kind: str, difficulty: int) -> bool:
    return kind in {"geometry", "function", "statistics", "probability"} and difficulty >= 2


def _question_payload(section: dict[str, Any], difficulty: int) -> dict[str, Any]:
    section_id = section["id"]
    label = section["label"]
    title = section["title"]
    kind = _topic_kind(title)
    question_id = f"q-{section_id}-{difficulty:03d}"
    level = DIFFICULTY_LABELS[difficulty]

    if kind == "equation":
        prompt = {
            1: rf"解方程：$2x+3=11$，并说明每一步等式变形依据。",
            2: rf"围绕「{label}」列方程解决：一个数的 3 倍减 5 等于 16，求这个数。",
            3: rf"小明解「{label}」题时把移项后的符号写反了。请设计一个一元一次方程，指出错误并改正。",
        }[difficulty]
        steps = ["设未知数并列出方程", "按等式性质变形", "检验结果是否符合题意"]
    elif kind == "inequality":
        prompt = {
            1: r"解不等式：$2x-3>5$，并把解集用文字说明。",
            2: rf"围绕「{label}」解不等式 $3(x-1)\le 2x+4$，说明哪一步需要改变或保持不等号方向。",
            3: rf"设计一个解集为 $x\ge -2$ 的一元一次不等式，并讲清构造理由。",
        }[difficulty]
        steps = ["去括号或移项", "合并同类项并化系数", "写出解集并说明边界"]
    elif kind == "function":
        prompt = {
            1: rf"根据「{label}」写出一个变量关系，并判断它是不是函数关系。",
            2: rf"如图，观察函数图像的大致变化趋势，说出 $y$ 随 $x$ 增大如何变化。",
            3: rf"已知一次函数经过点 $(0,2)$ 和 $(2,6)$，求函数解析式并说明图像特征。",
        }[difficulty]
        steps = ["确定自变量和因变量", "读取点或变化趋势", "用解析式或图像语言表达结论"]
    elif kind == "statistics":
        prompt = {
            1: rf"围绕「{label}」读一组数据：8、10、10、12、15，求平均数并说明含义。",
            2: "如图，根据条形统计图判断哪一组数据最大，并说明你的读图依据。",
            3: rf"为「{label}」设计一次小调查，说明调查对象、记录方式和怎样避免数据遗漏。",
        }[difficulty]
        steps = ["明确统计对象", "读取或计算关键数据", "用一句话解释统计结论"]
    elif kind == "probability":
        prompt = {
            1: r"袋中有 2 个红球、3 个蓝球，随机摸出 1 个，求摸到红球的概率。",
            2: "如图，袋中有红、蓝、白三类球。若红球 2 个、蓝球 3 个、白球 1 个，求摸到蓝球的概率。",
            3: rf"围绕「{label}」设计一个概率为 $\dfrac{1}{3}$ 的摸球实验，并说明样本总数和有利结果数。",
        }[difficulty]
        steps = ["列出所有等可能结果", "数出有利结果", "写成概率并化简"]
    elif kind == "geometry":
        prompt = {
            1: rf"观察「{label}」中的基本图形，说出图中至少两个关键元素及它们的关系。",
            2: "如图，结合已标出的线段或角，说明可以推出哪个几何结论。",
            3: rf"围绕「{label}」写一段完整推理：先列已知，再说明判定依据，最后写结论。",
        }[difficulty]
        steps = ["读图并标出已知量", "选择对应的定义或判定方法", "按因为所以写出结论"]
    elif kind == "radical":
        prompt = {
            1: r"求 $\sqrt{49}$ 和 $-\sqrt{49}$ 的值，并说明它们的区别。",
            2: rf"围绕「{label}」化简 $\sqrt{{72}}$，写出把完全平方数提出的过程。",
            3: rf"判断 $\sqrt{{x-4}}$ 在实数范围内有意义时 $x$ 的取值范围，并说明理由。",
        }[difficulty]
        steps = ["找出定义或非负条件", "进行化简或求值", "写出最终结论并检查条件"]
    elif kind == "algebra":
        prompt = {
            1: r"化简：$3a+2a-a$，并说明同类项为什么可以合并。",
            2: rf"围绕「{label}」计算 $(x+2)(x+3)$，写出展开过程。",
            3: rf"把 $x^2+5x+6$ 分解因式，并说明你怎样找到两个数。",
        }[difficulty]
        steps = ["识别同类项或结构", "按运算法则展开或合并", "检查结果是否还能化简"]
    else:
        prompt = {
            1: rf"请围绕「{label}」讲清一个核心概念，并举一个简单例子。",
            2: rf"给出一个与「{label}」有关的计算或判断题，写出完整步骤并解释依据。",
            3: rf"总结「{label}」里一个容易出错的地方，设计例子说明正确做法。",
        }[difficulty]
        steps = [f"说出「{label}」的核心概念", "列出一个代表性步骤", "总结易错点并修正"]

    question: dict[str, Any] = {
        "questionId": question_id,
        "sectionId": section_id,
        "sectionLabel": label,
        "prompt": prompt,
        "hint": f"提示：这是「{level}」题，先抓住「{title}」的核心规则，再按步骤讲清理由。",
        "referenceSteps": steps,
        "difficulty": difficulty,
        "tags": _tags(title, kind),
        "quality": "generated_seed",
    }

    if _needs_diagram(kind, difficulty):
        asset = f"assets/questions/diagrams/{question_id}.svg"
        question["image"] = {
            "asset": asset,
            "alt": f"{label} 的配图，用于读图、推理或解释题意",
        }
        (DATA_DIAGRAMS / Path(asset).name).write_text(
            _svg(kind, title), encoding="utf-8"
        )

    return question


def _copy_outputs() -> None:
    MOBILE_OUT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(DATA_OUT, MOBILE_OUT)
    if MOBILE_DIAGRAMS.exists():
        shutil.rmtree(MOBILE_DIAGRAMS)
    MOBILE_DIAGRAMS.mkdir(parents=True, exist_ok=True)
    for svg in sorted(DATA_DIAGRAMS.glob("*.svg")):
        shutil.copyfile(svg, MOBILE_DIAGRAMS / svg.name)


def main() -> None:
    curriculum = json.loads(CURRICULUM.read_text(encoding="utf-8"))
    DATA_OUT.parent.mkdir(parents=True, exist_ok=True)
    DATA_DIAGRAMS.mkdir(parents=True, exist_ok=True)
    for old_svg in DATA_DIAGRAMS.glob("*.svg"):
        old_svg.unlink()

    questions: list[dict[str, Any]] = []
    for book in curriculum["books"]:
        for chapter in book["chapters"]:
            for section in chapter["sections"]:
                section_id = section["id"]
                section_label = section["label"]
                if section_id in CH16_QUESTIONS:
                    for item in CH16_QUESTIONS[section_id]:
                        questions.append(
                            {
                                **item,
                                "sectionId": section_id,
                                "sectionLabel": section_label,
                            }
                        )
                    continue
                for difficulty in (1, 2, 3):
                    questions.append(_question_payload(section, difficulty))

    DATA_OUT.write_text(
        json.dumps(
            {
                "version": "1.1.0",
                "source": "data/curriculum/pep-junior-math.json",
                "questionPolicy": "3 questions per section: basic, practice, challenge; SVG diagrams for visual topics.",
                "questions": questions,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    _copy_outputs()
    section_count = len({q["sectionId"] for q in questions})
    diagram_count = len(list(DATA_DIAGRAMS.glob("*.svg")))
    print(
        f"wrote questions={len(questions)} sections={section_count} diagrams={diagram_count}"
    )


if __name__ == "__main__":
    main()
