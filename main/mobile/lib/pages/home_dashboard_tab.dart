import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/mock_lecture_repository.dart';
import '../services/progress_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端「今日」Tab：紧凑仪表盘，不含整册目录。
class HomeDashboardTab extends StatelessWidget {
  const HomeDashboardTab({
    super.key,
    required this.curriculum,
    required this.studentGradeLabel,
    required this.books,
    required this.pendingAssignments,
    required this.onSectionTap,
    required this.onAssignmentsTap,
  });

  final MathCurriculum curriculum;
  final String studentGradeLabel;
  final List<CurriculumBook> books;
  final int pendingAssignments;
  final ValueChanged<CurriculumSection> onSectionTap;
  final VoidCallback onAssignmentsTap;

  @override
  Widget build(BuildContext context) {
    final recommended = _recommendedSection();
    final questionCount =
        recommended == null
            ? 0
            : MockLectureRepository.instance.questionCountForSection(
              recommended.id,
            );

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageEdge,
        12,
        AppSpacing.pageEdge,
        24,
      ),
      children: [
        _CompactGreeting(
          publisher: curriculum.publisher,
          gradeLabel: studentGradeLabel,
          subjectLabel: curriculum.subjectLabel,
        ),
        if (pendingAssignments > 0) ...[
          const SizedBox(height: AppSpacing.itemGap),
          _PendingAssignmentsBanner(
            count: pendingAssignments,
            onTap: onAssignmentsTap,
          ),
        ],
        const SizedBox(height: AppSpacing.moduleGap),
        StudyPanel(
          tone: StudyPanelTone.primary,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                title: '今日继续',
                subtitle:
                    recommended == null
                        ? '题库准备中'
                        : recommended.label,
                icon: Icons.play_circle_outline,
                action:
                    recommended == null
                        ? null
                        : FilledButton(
                          onPressed: () => onSectionTap(recommended),
                          child: const Text('开始讲题'),
                        ),
              ),
              if (recommended != null) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StudyStatPill(
                      label: '本节题量',
                      value: questionCount > 0 ? '$questionCount 道' : '可练',
                      icon: Icons.edit_note_outlined,
                    ),
                    AnimatedBuilder(
                      animation: ProgressRepository.instance,
                      builder: (context, _) {
                        final progress = ProgressRepository.instance
                            .progressFor(recommended.id);
                        return StudyStatPill(
                          label: '掌握度',
                          value:
                              !progress.hasAnyCompletion
                                  ? '未开始'
                                  : '${progress.masteryScore}/100',
                          icon: Icons.insights_outlined,
                          accent: AppPalette.primaryAccent,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        Text('快捷入口', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        _QuickEntryGrid(
          entries: [
            _QuickEntry(
              '每日挑战',
              Icons.where_to_vote_outlined,
              AppPalette.primaryAccent,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DailyChallengePage()),
              ),
            ),
            _QuickEntry(
              '我的作业',
              Icons.assignment_outlined,
              AppPalette.primary,
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StudentAssignmentsPage(),
                ),
              ),
            ),
            _QuickEntry(
              '晶石奖励',
              Icons.diamond_outlined,
              AppPalette.primary,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ShopPage()),
              ),
            ),
            _QuickEntry(
              '学习榜单',
              Icons.emoji_events_outlined,
              AppPalette.primaryAccent,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LeaderboardPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        StudyPanel(
          tone: StudyPanelTone.quiet,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.tips_and_updates_outlined, color: AppPalette.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '完整章节目录在底部「课程」；挑战与奖励在「更多」。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  CurriculumSection? _recommendedSection() {
    for (final book in books) {
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          if (section.isAvailable ||
              MockLectureRepository.instance.questionCountForSection(
                    section.id,
                  ) >
                  0) {
            return section;
          }
        }
      }
    }
    return null;
  }
}

class _CompactGreeting extends StatelessWidget {
  const _CompactGreeting({
    required this.publisher,
    required this.gradeLabel,
    required this.subjectLabel,
  });

  final String publisher;
  final String gradeLabel;
  final String subjectLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '你好，今天也要讲明白',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$publisher · $gradeLabel$subjectLabel',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppPalette.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppPalette.outlineSoft),
          ),
          child: const Icon(
            Icons.school_outlined,
            color: AppPalette.primary,
            size: 28,
          ),
        ),
      ],
    );
  }
}

class _QuickEntryGrid extends StatelessWidget {
  const _QuickEntryGrid({required this.entries});

  final List<_QuickEntry> entries;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children:
              entries
                  .map(
                    (e) => SizedBox(
                      width: width,
                      child: _QuickEntryTile(entry: e),
                    ),
                  )
                  .toList(),
        );
      },
    );
  }
}

class _QuickEntry {
  const _QuickEntry(this.label, this.icon, this.color, this.onTap);
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
}

class _QuickEntryTile extends StatelessWidget {
  const _QuickEntryTile({required this.entry});

  final _QuickEntry entry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surface,
      borderRadius: AppRadius.cardR,
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap: entry.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppPalette.outlineSoft),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: entry.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(entry.icon, color: entry.color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: entry.color),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingAssignmentsBanner extends StatelessWidget {
  const _PendingAssignmentsBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppPalette.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.assignment, color: AppPalette.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '家长布置了 $count 项作业',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '点这里查看截止时间与题面',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppPalette.primary),
            ],
          ),
        ),
      ),
    );
  }
}
