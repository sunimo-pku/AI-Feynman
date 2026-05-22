import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../theme/app_theme.dart';
import '../widgets/curriculum_catalog.dart';
import '../widgets/study_layout.dart';
import 'curriculum_book_page.dart';

/// 学生端「课程」Tab：年级筛选 + 分册入口，目录在二级页展开。
class CurriculumTabPage extends StatefulWidget {
  const CurriculumTabPage({
    super.key,
    required this.curriculum,
    required this.initialGradeLabel,
    required this.onSectionTap,
    required this.onSectionReview,
    required this.onGradeChanged,
  });

  final MathCurriculum curriculum;
  final String initialGradeLabel;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;
  final ValueChanged<String> onGradeChanged;

  @override
  State<CurriculumTabPage> createState() => _CurriculumTabPageState();
}

class _CurriculumTabPageState extends State<CurriculumTabPage> {
  static const _grades = ['七年级', '八年级', '九年级'];
  late String _selectedGrade = widget.initialGradeLabel;

  @override
  void didUpdateWidget(CurriculumTabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialGradeLabel != widget.initialGradeLabel) {
      _selectedGrade = widget.initialGradeLabel;
    }
  }

  List<CurriculumBook> get _booksForGrade {
    final matched =
        widget.curriculum.books
            .where((b) => b.gradeLabel == _selectedGrade)
            .toList();
    return matched.isEmpty ? widget.curriculum.books : matched;
  }

  @override
  Widget build(BuildContext context) {
    final books = _booksForGrade;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageEdge,
        12,
        AppSpacing.pageEdge,
        24,
      ),
      children: [
        Text(
          '选择年级与册别',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '每册单独打开章节目录，不再在首页一次性铺开。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 14),
        SegmentedButton<String>(
          segments:
              _grades
                  .map((g) => ButtonSegment(value: g, label: Text(g)))
                  .toList(),
          selected: {_selectedGrade},
          onSelectionChanged: (value) {
            final grade = value.first;
            setState(() => _selectedGrade = grade);
            widget.onGradeChanged(grade);
          },
        ),
        const SizedBox(height: AppSpacing.moduleGap),
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
                          onSectionTap: widget.onSectionTap,
                          onSectionReview: widget.onSectionReview,
                        ),
                  ),
                );
              },
            ),
          ),
        ),
        if (books.isEmpty)
          const StudyPanel(
            child: Text('该年级暂无目录数据，请稍后再试。'),
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
