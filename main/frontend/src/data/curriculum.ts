import raw from "@curriculum/pep-junior-math.json";
import type {
  ContentStatus,
  CurriculumBook,
  CurriculumChapter,
  CurriculumSection,
  MathCurriculum,
} from "./curriculum.types";

export type {
  ContentStatus,
  CurriculumBook,
  CurriculumChapter,
  CurriculumSection,
  MathCurriculum,
  SectionType,
} from "./curriculum.types";

/** 人教版初中数学完整目录（6 册 · 29 章 · 90 节） */
export const mathCurriculum = raw as MathCurriculum;

export function getBooks(): CurriculumBook[] {
  return mathCurriculum.books;
}

export function getBook(bookId: string): CurriculumBook | undefined {
  return mathCurriculum.books.find((b) => b.id === bookId);
}

export function getChapter(chapterId: string): CurriculumChapter | undefined {
  for (const book of mathCurriculum.books) {
    const chapter = book.chapters.find((c) => c.id === chapterId);
    if (chapter) return chapter;
  }
  return undefined;
}

export function getSection(sectionId: string): CurriculumSection | undefined {
  for (const book of mathCurriculum.books) {
    for (const chapter of book.chapters) {
      const section = chapter.sections.find((s) => s.id === sectionId);
      if (section) return section;
    }
  }
  return undefined;
}

/** 扁平列表，便于搜索 / 下拉选择 */
export function listAllSections(): Array<
  CurriculumSection & { book: CurriculumBook; chapter: CurriculumChapter }
> {
  const result: Array<
    CurriculumSection & { book: CurriculumBook; chapter: CurriculumChapter }
  > = [];
  for (const book of mathCurriculum.books) {
    for (const chapter of book.chapters) {
      for (const section of chapter.sections) {
        result.push({ ...section, book, chapter });
      }
    }
  }
  return result;
}

export function isSectionAvailable(section: CurriculumSection): boolean {
  return section.contentStatus === "available";
}

/** 将某小节标记为已上线（V1 确定章节后调用，或后端覆盖） */
export function withSectionStatus(
  sectionId: string,
  contentStatus: ContentStatus,
): MathCurriculum {
  return {
    ...mathCurriculum,
    books: mathCurriculum.books.map((book) => ({
      ...book,
      chapters: book.chapters.map((chapter) => ({
        ...chapter,
        sections: chapter.sections.map((section) =>
          section.id === sectionId ? { ...section, contentStatus } : section,
        ),
      })),
    })),
  };
}
