/** 人教版初中数学目录 · 类型定义（与 data/curriculum/pep-junior-math.json 同步） */

export type SectionType = "lesson" | "topic_study";

/** V1：仅 available 的小节可进入练习 */
export type ContentStatus = "available" | "coming_soon";

export interface CurriculumSection {
  id: string;
  number: string;
  title: string;
  label: string;
  type: SectionType;
  contentStatus: ContentStatus;
}

export interface CurriculumChapter {
  id: string;
  number: number;
  title: string;
  label: string;
  sections: CurriculumSection[];
}

export interface CurriculumBook {
  id: string;
  publisher: string;
  grade: 7 | 8 | 9;
  gradeLabel: string;
  semester: 1 | 2;
  semesterLabel: string;
  label: string;
  chapters: CurriculumChapter[];
}

export interface MathCurriculum {
  version: string;
  subject: "math";
  subjectLabel: string;
  stage: "junior_high";
  stageLabel: string;
  publisher: string;
  books: CurriculumBook[];
}
