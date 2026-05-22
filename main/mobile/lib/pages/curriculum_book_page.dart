import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../theme/app_theme.dart';
import '../widgets/curriculum_catalog.dart';
import '../widgets/study_layout.dart';

/// 单册课程详情：按章展示小节，避免首页堆叠整本目录。
class CurriculumBookPage extends StatelessWidget {
  const CurriculumBookPage({
    super.key,
    required this.book,
    required this.onSectionTap,
    required this.onSectionReview,
  });

  final CurriculumBook book;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;

  @override
  Widget build(BuildContext context) {
    final practicable = countPracticableSections(book);
    final totalSections = book.chapters.fold<int>(
      0,
      (sum, c) => sum + c.sections.length,
    );

    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: Text(book.label)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          StudyPanel(
            tone: StudyPanelTone.primary,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${book.chapters.length} 章 · $totalSections 节 · $practicable 节可练',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: AppPalette.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.moduleGap),
          ...book.chapters.map(
            (chapter) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
              child: StudyPanel(
                child: CurriculumChapterBlock(
                  chapter: chapter,
                  onSectionTap: onSectionTap,
                  onSectionReview: onSectionReview,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
