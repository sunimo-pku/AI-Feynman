import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../theme/app_theme.dart';
import '../widgets/curriculum_catalog.dart';
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
          ...books.map(
            (book) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
              child: _BookListTile(
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
            ),
          ),
      ],
    );
  }
}

class _BookListTile extends StatelessWidget {
  const _BookListTile({required this.book, required this.onTap});

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

    return Material(
      color: AppPalette.surface,
      borderRadius: AppRadius.cardR,
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            border: Border.all(
              color:
                  hasPractice
                      ? AppPalette.primary.withValues(alpha: 0.25)
                      : AppPalette.outline,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppPalette.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  hasPractice ? Icons.menu_book : Icons.lock_outline,
                  color: hasPractice ? AppPalette.primary : AppPalette.comingSoon,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${book.chapters.length} 章 · $totalSections 节 · $practicable 节可练',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            hasPractice
                                ? AppPalette.primaryAccent
                                : AppPalette.comingSoon,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppPalette.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
