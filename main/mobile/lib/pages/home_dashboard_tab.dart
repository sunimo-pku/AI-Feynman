import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/mock_lecture_repository.dart';
import '../services/auth_service.dart';
import '../services/progress_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端「今日」Tab：自习室叙事首页，仅展示账号年级下的推荐小节。
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
        16,
        AppSpacing.pageEdge,
        32,
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
          tone: StudyPanelTone.surface,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                title: recommended == null ? '今天想练哪一节？' : '今天想继续练',
                subtitle:
                    recommended == null
                        ? '题库准备中，先去「课程」看看'
                        : recommended.label,
                accent: AppPalette.primaryAccent,
                action:
                    recommended == null
                        ? null
                        : FilledButton(
                          onPressed: () => onSectionTap(recommended),
                          child: const Text('开始讲题'),
                        ),
              ),
              if (recommended != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StudySoftTag(
                      text:
                          questionCount > 0 ? '本节 $questionCount 道题' : '本节可练',
                      accent: AppPalette.primary,
                    ),
                    AnimatedBuilder(
                      animation: ProgressRepository.instance,
                      builder: (context, _) {
                        final progress = ProgressRepository.instance
                            .progressFor(recommended.id);
                        return StudySoftTag(
                          text:
                              !progress.hasAnyCompletion
                                  ? '还没开始讲'
                                  : '已练 ${progress.completedRounds} 轮',
                          accent: AppPalette.primaryAccent,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const StudyCompanionRow(),
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
              subtitle: '帮同学找错',
              icon: Icons.edit_outlined,
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
              subtitle: '家长布置的',
              icon: Icons.description_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const StudentAssignmentsPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '晶石商城',
              subtitle: '兑换文具',
              icon: Icons.card_giftcard_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShopPage()),
                  ),
            ),
            StudyToolCell(
              label: '学习榜单',
              subtitle: '看看排名',
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
            height: 1.5,
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

String _timeGreeting() {
  final hour = DateTime.now().hour;
  if (hour < 11) return '上午好';
  if (hour < 14) return '中午好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

class _CompactGreeting extends StatelessWidget {
  const _CompactGreeting({required this.gradeLabel});

  final String gradeLabel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        final name = AuthService.instance.currentUsername;
        final who = name.isEmpty ? '同学' : name;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_timeGreeting()}，$who',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              '找一节想讲的题，讲给同伴听就好',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            StudySoftTag(
              text: gradeLabel,
              accent: AppPalette.primary,
            ),
          ],
        );
      },
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
      color: AppPalette.warmTint.withValues(alpha: 0.55),
      borderRadius: AppRadius.cardR,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.cardR,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 20,
                color: AppPalette.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '家长布置了 $count 项作业',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppPalette.primary.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
