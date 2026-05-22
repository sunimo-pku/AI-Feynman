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
        12,
        AppSpacing.pageEdge,
        24,
      ),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppPalette.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppPalette.primary.withValues(alpha: 0.28),
                ),
              ),
              child: Text(
                studentGradeLabel,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppPalette.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '本学期目录',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '年级在注册时选定；若要更换，请到「我的」→ 编辑资料修改。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        if (books.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppPalette.surface,
              borderRadius: AppRadius.cardR,
              border: Border.all(color: AppPalette.outlineSoft),
            ),
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
    final hasPractice = practicable > 0;

    return StudyDenseTile(
      onTap: onTap,
      title: book.label,
      subtitle: '${book.chapters.length} 章 · $totalSections 节 · $practicable 节可练',
      icon: hasPractice ? Icons.menu_book_outlined : Icons.lock_outline,
      accent: hasPractice ? AppPalette.primary : AppPalette.comingSoon,
      trailing: const Icon(Icons.chevron_right, size: 20, color: AppPalette.textSecondary),
    );
  }
}
