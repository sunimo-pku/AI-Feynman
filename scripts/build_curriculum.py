#!/usr/bin/env python3
"""Generate pep-junior-math curriculum JSON from structured source."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_JSON = ROOT / "data" / "curriculum" / "pep-junior-math.json"

# (book_key, grade, semester, semester_label, chapters)
# chapter: (num, title, sections)  section: (num, title)
CURRICULUM = [
    (
        "g7-up",
        7,
        1,
        "上册",
        [
            (1, "有理数", [(f"1.{i}", t) for i, t in enumerate(
                ["正数和负数", "有理数", "有理数的加减法", "有理数的乘除法", "有理数的乘方"], 1)]),
            (2, "整式的加减", [("2.1", "整式"), ("2.2", "整式的加减")]),
            (3, "一元一次方程", [
                ("3.1", "从算式到方程"),
                ("3.2", "解一元一次方程(一)——合并同类项与移项"),
                ("3.3", "解一元一次方程(二)——去括号与去分母"),
                ("3.4", "实际问题与一元一次方程"),
            ]),
            (4, "几何图形初步", [
                ("4.1", "几何图形"),
                ("4.2", "直线、射线、线段"),
                ("4.3", "角"),
                ("4.4", "设计制作长方体形状的包装纸盒"),
            ]),
        ],
    ),
    (
        "g7-down",
        7,
        2,
        "下册",
        [
            (5, "相交线与平行线", [
                ("5.1", "相交线"),
                ("5.2", "平行线及其判定"),
                ("5.3", "平行线的性质"),
                ("5.4", "平移"),
            ]),
            (6, "实数", [("6.1", "平方根"), ("6.2", "立方根"), ("6.3", "实数")]),
            (7, "平面直角坐标系", [("7.1", "平面直角坐标系"), ("7.2", "坐标方法的简单应用")]),
            (8, "二元一次方程组", [
                ("8.1", "二元一次方程组"),
                ("8.2", "消元——解二元一次方程组"),
                ("8.3", "实际问题与二元一次方程组"),
                ("8.4", "三元一次方程组的解法"),
            ]),
            (9, "不等式与不等式组", [
                ("9.1", "不等式"),
                ("9.2", "一元一次不等式"),
                ("9.3", "一元一次不等式组"),
            ]),
            (10, "数据的收集、整理与描述", [
                ("10.1", "统计调查"),
                ("10.2", "直方图"),
                ("10.3", "从数据谈节水"),
            ]),
        ],
    ),
    (
        "g8-up",
        8,
        1,
        "上册",
        [
            (11, "三角形", [
                ("11.1", "与三角形有关的线段"),
                ("11.2", "与三角形有关的角"),
                ("11.3", "多边形及其内角和"),
            ]),
            (12, "全等三角形", [
                ("12.1", "全等三角形"),
                ("12.2", "三角形全等的判定"),
                ("12.3", "角的平分线的性质"),
            ]),
            (13, "轴对称", [
                ("13.1", "轴对称"),
                ("13.2", "画轴对称图形"),
                ("13.3", "等腰三角形"),
                ("13.4", "最短路径问题"),
            ]),
            (14, "整式的乘法与因式分解", [
                ("14.1", "整式的乘法"),
                ("14.2", "乘法公式"),
                ("14.3", "因式分解"),
            ]),
            (15, "分式", [("15.1", "分式"), ("15.2", "分式的运算"), ("15.3", "分式方程")]),
        ],
    ),
    (
        "g8-down",
        8,
        2,
        "下册",
        [
            (16, "二次根式", [
                ("16.1", "二次根式"),
                ("16.2", "二次根式的乘除"),
                ("16.3", "二次根式的加减"),
            ]),
            (17, "勾股定理", [("17.1", "勾股定理"), ("17.2", "勾股定理的逆定理")]),
            (18, "平行四边形", [("18.1", "平行四边形"), ("18.2", "特殊的平行四边形")]),
            (19, "一次函数", [
                ("19.1", "函数"),
                ("19.2", "一次函数"),
                ("19.3", "选择方案"),
            ]),
            (20, "数据的分析", [
                ("20.1", "数据的集中趋势"),
                ("20.2", "数据的波动程度"),
                ("20.3", "体质健康测试中的数据"),
            ]),
        ],
    ),
    (
        "g9-up",
        9,
        1,
        "上册",
        [
            (21, "一元二次方程", [
                ("21.1", "一元二次方程"),
                ("21.2", "解一元二次方程"),
                ("21.3", "实际问题与一元二次方程"),
            ]),
            (22, "二次函数", [
                ("22.1", "二次函数的图象和性质"),
                ("22.2", "二次函数与一元二次方程"),
                ("22.3", "实际问题与二次函数"),
            ]),
            (23, "旋转", [
                ("23.1", "图形的旋转"),
                ("23.2", "中心对称"),
                ("23.3", "图案设计"),
            ]),
            (24, "圆", [
                ("24.1", "圆的有关性质"),
                ("24.2", "点和圆、直线和圆的位置关系"),
                ("24.3", "正多边形和圆"),
                ("24.4", "弧长和扇形面积"),
            ]),
            (25, "概率初步", [
                ("25.1", "随机事件与概率"),
                ("25.2", "用列举法求概率"),
                ("25.3", "用频率估计概率"),
            ]),
        ],
    ),
    (
        "g9-down",
        9,
        2,
        "下册",
        [
            (26, "二次函数", [
                ("26.1", "二次函数及其图象"),
                ("26.2", "用函数观点看一元二次方程"),
                ("26.3", "实际问题与二次函数"),
            ]),
            (27, "相似", [
                ("27.1", "图形的相似"),
                ("27.2", "相似三角形"),
                ("27.3", "位似"),
            ]),
            (28, "锐角三角函数", [("28.1", "锐角三角函数"), ("28.2", "解直角三角形")]),
            (29, "投影与视图", [
                ("29.1", "投影"),
                ("29.2", "三视图"),
                ("29.3", "制作立体模型"),
            ]),
        ],
    ),
]

TOPIC_SECTIONS = {
    "4.4", "10.3", "13.4", "19.3", "20.3", "23.3", "29.3",
}

# V1 唯一有内容的章节：八年级下册 · 第十六章 二次根式
V1_LAUNCH_BOOK_KEY = "g8-down"
V1_LAUNCH_CHAPTER_NUM = 16
V1_LAUNCH_CHAPTER_TITLE = "二次根式"


def section_type(num: str, title: str) -> str:
    if num in TOPIC_SECTIONS:
        return "topic_study"
    return "lesson"


def section_label(num: str, title: str, stype: str) -> str:
    if stype == "topic_study":
        return f"{num} 课题学习 {title}"
    return f"{num} {title}"


def build() -> dict:
    grade_labels = {7: "七年级", 8: "八年级", 9: "九年级"}
    books = []
    v1_book_id = f"pep-{V1_LAUNCH_BOOK_KEY}"
    v1_chapter_id = f"{v1_book_id}-ch{V1_LAUNCH_CHAPTER_NUM}"
    v1_section_ids: list[str] = []
    v1_book_label = ""

    for book_key, grade, semester, sem_label, chapters in CURRICULUM:
        book_id = f"pep-{book_key}"
        ch_list = []
        for ch_num, ch_title, sections in chapters:
            ch_id = f"{book_id}-ch{ch_num}"
            is_v1_chapter = (
                book_key == V1_LAUNCH_BOOK_KEY and ch_num == V1_LAUNCH_CHAPTER_NUM
            )
            sec_list = []
            for sec_num, sec_title in sections:
                stype = section_type(sec_num, sec_title)
                sec_id = f"{book_id}-s{sec_num.replace('.', '-')}"
                if is_v1_chapter:
                    v1_section_ids.append(sec_id)
                sec_list.append({
                    "id": sec_id,
                    "number": sec_num,
                    "title": sec_title,
                    "label": section_label(sec_num, sec_title, stype),
                    "type": stype,
                    "contentStatus": "available" if is_v1_chapter else "coming_soon",
                })
            ch_list.append({
                "id": ch_id,
                "number": ch_num,
                "title": ch_title,
                "label": f"第{ _cn_num(ch_num) }章 {ch_title}",
                "sections": sec_list,
            })

        book_label = f"{grade_labels[grade]}{sem_label}"
        if book_id == v1_book_id:
            v1_book_label = book_label

        books.append({
            "id": book_id,
            "publisher": "人教版",
            "grade": grade,
            "gradeLabel": grade_labels[grade],
            "semester": semester,
            "semesterLabel": sem_label,
            "label": book_label,
            "chapters": ch_list,
        })

    return {
        "version": "1.0.0",
        "subject": "math",
        "subjectLabel": "数学",
        "stage": "junior_high",
        "stageLabel": "初中",
        "publisher": "人教版",
        "v1Launch": {
            "bookId": v1_book_id,
            "bookLabel": v1_book_label,
            "chapterId": v1_chapter_id,
            "chapterNumber": V1_LAUNCH_CHAPTER_NUM,
            "chapterTitle": V1_LAUNCH_CHAPTER_TITLE,
            "chapterLabel": f"第{_cn_num(V1_LAUNCH_CHAPTER_NUM)}章 {V1_LAUNCH_CHAPTER_TITLE}",
            "sectionIds": v1_section_ids,
        },
        "books": books,
    }


def _cn_num(n: int) -> str:
    mapping = {
        1: "一", 2: "二", 3: "三", 4: "四", 5: "五",
        6: "六", 7: "七", 8: "八", 9: "九", 10: "十",
        11: "十一", 12: "十二", 13: "十三", 14: "十四", 15: "十五",
        16: "十六", 17: "十七", 18: "十八", 19: "十九", 20: "二十",
        21: "二十一", 22: "二十二", 23: "二十三", 24: "二十四", 25: "二十五",
        26: "二十六", 27: "二十七", 28: "二十八", 29: "二十九",
    }
    return mapping[n]


def main() -> None:
    data = build()
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    section_count = sum(
        len(ch["sections"])
        for book in data["books"]
        for ch in book["chapters"]
    )
    print(f"Wrote {OUT_JSON}")
    print(f"Books: {len(data['books'])}, Chapters: 29, Sections: {section_count}")


if __name__ == "__main__":
    main()
