import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/mock_lecture_repository.dart';
import '../data/progress_models.dart';
import '../services/progress_repository.dart';
import '../services/review_repository.dart';
import '../theme/app_theme.dart';

/// 课程目录通用组件：小节 pill、回顾按钮、状态徽标、章块。
bool sectionPracticeAvailable(CurriculumSection section) {
  return section.practiceAvailable ||
      MockLectureRepository.instance.questionCountForSection(section.id) > 0;
}

class CurriculumChapterBlock extends StatelessWidget {
  const CurriculumChapterBlock({
    super.key,
    required this.chapter,
    required this.onSectionTap,
    required this.onSectionReview,
  });

  final CurriculumChapter chapter;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;

  @override
  Widget build(BuildContext context) {
    final chapterAvailable = chapter.sections.any(sectionPracticeAvailable);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                chapter.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color:
                      chapterAvailable
                          ? AppPalette.textPrimary
                          : AppPalette.comingSoon,
                ),
              ),
              if (!chapterAvailable) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: AppPalette.comingSoon,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                chapter.sections
                    .map(
                      (s) => CurriculumSectionPill(
                        section: s,
                        onTap: onSectionTap,
                        onReview: onSectionReview,
                      ),
                    )
                    .toList(),
          ),
        ],
      ),
    );
  }
}

class CurriculumSectionPill extends StatelessWidget {
  const CurriculumSectionPill({
    super.key,
    required this.section,
    required this.onTap,
    required this.onReview,
  });

  final CurriculumSection section;
  final ValueChanged<CurriculumSection> onTap;
  final ValueChanged<CurriculumSection> onReview;

  @override
  Widget build(BuildContext context) {
    final available = sectionPracticeAvailable(section);
    if (!available) {
      return _buildPill(context, progress: null);
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        ProgressRepository.instance,
        ReviewRepository.instance,
      ]),
      builder: (context, _) {
        final progress = ProgressRepository.instance.progressFor(section.id);
        return _buildPill(context, progress: progress);
      },
    );
  }

  Widget _buildPill(
    BuildContext context, {
    required SectionProgress? progress,
  }) {
    final available = sectionPracticeAvailable(section);
    final hasProgress = progress != null && progress.hasAnyCompletion;
    final bg =
        available
            ? AppPalette.primary.withValues(alpha: 0.06)
            : AppPalette.comingSoon.withValues(alpha: 0.06);
    final spineColor = available ? AppPalette.primary : AppPalette.comingSoon;
    final textColor = available ? AppPalette.primary : AppPalette.comingSoon;

    final hasReview =
        available && ReviewRepository.instance.hasRecordsForSection(section.id);

    final pill = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchMin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap: () => onTap(section),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.buttonR,
              boxShadow: available ? AppShadows.paper : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 3,
                  height: 28,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: spineColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(
                  available
                      ? (hasProgress
                          ? Icons.check_circle
                          : Icons.play_circle_outline)
                      : Icons.lock_outline,
                  size: 18,
                  color: hasProgress ? AppPalette.primaryAccent : textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  section.label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                CurriculumSectionStatusBadge(
                  available: available,
                  progress: progress,
                  sectionId: section.id,
                  knowledgePointCount: section.knowledgePointCount,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!available) return pill;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill,
        const SizedBox(width: 6),
        CurriculumSectionReviewButton(
          section: section,
          hasReview: hasReview,
          onReview: onReview,
        ),
      ],
    );
  }
}

class CurriculumSectionReviewButton extends StatelessWidget {
  const CurriculumSectionReviewButton({
    super.key,
    required this.section,
    required this.hasReview,
    required this.onReview,
  });

  final CurriculumSection section;
  final bool hasReview;
  final ValueChanged<CurriculumSection> onReview;

  @override
  Widget build(BuildContext context) {
    final color =
        hasReview ? AppPalette.primaryAccent : AppPalette.textSecondary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchMin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap: () => onReview(section),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: hasReview ? 0.10 : 0.05),
              borderRadius: AppRadius.capsuleR,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_edu_outlined, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  '回顾',
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CurriculumSectionStatusBadge extends StatelessWidget {
  const CurriculumSectionStatusBadge({
    super.key,
    required this.available,
    required this.progress,
    required this.sectionId,
    this.knowledgePointCount = 0,
  });

  final bool available;
  final SectionProgress? progress;
  final String sectionId;
  final int knowledgePointCount;

  @override
  Widget build(BuildContext context) {
    if (!available) {
      return _badge(color: AppPalette.comingSoon, bgAlpha: 0.14, text: '即将开放');
    }
    final p = progress;
    if (p == null || !p.hasAnyCompletion) {
      if (knowledgePointCount > 0) {
        return _badge(
          color: AppPalette.primaryAccent,
          bgAlpha: 0.12,
          text: '$knowledgePointCount 知识点 · 可练',
        );
      }
      final count = MockLectureRepository.instance.questionCountForSection(
        sectionId,
      );
      final text = count > 0 ? '$count 道题 · 可练' : '可练习';
      return _badge(color: AppPalette.primaryAccent, bgAlpha: 0.12, text: text);
    }
    return _badge(
      color: AppPalette.primaryAccent,
      bgAlpha: 0.14,
      text: '已练 ${p.completedRounds} 轮',
    );
  }

  Widget _badge({
    required Color color,
    required double bgAlpha,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 统计一册内可练小节数量。
int countPracticableSections(CurriculumBook book) {
  var n = 0;
  for (final chapter in book.chapters) {
    for (final section in chapter.sections) {
      if (sectionPracticeAvailable(section)) {
        n++;
      }
    }
  }
  return n;
}
