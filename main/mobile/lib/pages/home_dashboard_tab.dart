import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/mock_lecture_repository.dart';
import '../services/progress_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端「今日」Tab：紧凑仪表盘，仅展示账号年级下的推荐小节。
class HomeDashboardTab extends StatelessWidget {
  const HomeDashboardTab({
    super.key,
    required this.studentGradeLabel,
    required this.books,
    required this.pendingAssignments,
    required this.onSectionTap,
    required this.onAssignmentsTap,
  });

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
        _CompactGreeting(gradeLabel: studentGradeLabel),
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
        const StudySectionTitle(title: '快捷入口'),
        StudyToolGrid(
          cells: [
            StudyToolCell(
              label: '每日挑战',
              subtitle: '分步找错',
              icon: Icons.where_to_vote_outlined,
              color: AppPalette.primaryAccent,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DailyChallengePage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '我的作业',
              subtitle: '家长布置',
              icon: Icons.assignment_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const StudentAssignmentsPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '晶石商城',
              subtitle: '实物文具',
              icon: Icons.diamond_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShopPage()),
                  ),
            ),
            StudyToolCell(
              label: '学习榜单',
              subtitle: '冲榜',
              icon: Icons.emoji_events_outlined,
              color: AppPalette.primaryAccent,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const LeaderboardPage(),
                    ),
                  ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        Text(
          '完整章节目录在「课程」；换年级请去「我的」→ 编辑资料。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.45,
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
  const _CompactGreeting({required this.gradeLabel});

  final String gradeLabel;

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
              const SizedBox(height: 8),
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
                  '当前 $gradeLabel',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppPalette.primary,
                    fontWeight: FontWeight.w700,
                  ),
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

class _PendingAssignmentsBanner extends StatelessWidget {
  const _PendingAssignmentsBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.assignment_outlined, size: 20, color: AppPalette.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '家长布置了 $count 项作业',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppPalette.primary),
            ],
          ),
        ),
      ),
    );
  }
}
