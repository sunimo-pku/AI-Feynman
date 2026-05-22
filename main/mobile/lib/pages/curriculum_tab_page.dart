import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../theme/app_theme.dart';
import '../widgets/curriculum_catalog.dart';
import '../widgets/study_layout.dart';
import 'curriculum_book_page.dart';

/// 学生端「课程」Tab：仅展示账号年级下的上下册（年级只在「我的」修改）。
class CurriculumTabPage extends StatelessWidget {
  const CurriculumTabPage({
    super.key,
    required this.studentGradeLabel,
    required this.books,
    required this.onSectionTap,
    required this.onSectionReview,
  });

  final String studentGradeLabel;
  final List<CurriculumBook> books;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageEdge,
        16,
        AppSpacing.pageEdge,
        32,
      ),
      children: [
        Text(
          '本学期目录',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            StudySoftTag(text: studentGradeLabel, accent: AppPalette.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '换年级请去「我的」→ 编辑资料',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        if (books.isEmpty)
          StudyPanel(
            tone: StudyPanelTone.quiet,
            padding: const EdgeInsets.all(20),
            child: Text(
              '未找到 $studentGradeLabel 的课程目录，请到「我的」检查年级设置。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          StudyGroupedPanel(
            children:
                books
                    .map(
                      (book) => _BookDenseTile(
                        book: book,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder:
                                  (_) => CurriculumBookPage(
                                    book: book,
                                    onSectionTap: onSectionTap,
                                    onSectionReview: onSectionReview,
                                  ),
                            ),
                          );
                        },
                      ),
                    )
                    .toList(),
          ),
      ],
    );
  }
}

class _BookDenseTile extends StatelessWidget {
  const _BookDenseTile({required this.book, required this.onTap});

  final CurriculumBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final practicable = countPracticableSections(book);
    final totalSections = book.chapters.fold<int>(
      0,
      (sum, c) => sum + c.sections.length,
    );

    return StudyListRow(
      title: book.label,
      subtitle: '${book.chapters.length} 章 · $totalSections 节 · $practicable 节可练',
      onTap: onTap,
    );
  }
}
