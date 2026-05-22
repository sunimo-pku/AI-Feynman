import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端「更多」Tab：学习工具与扩展功能。
class MoreTabPage extends StatelessWidget {
  const MoreTabPage({super.key});

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
        Text(
          '学习工具',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '挑战、奖励与辅助功能；年级仅在「我的」→ 编辑资料中修改。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        StudyToolGrid(
          cells: [
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
              subtitle: '校/区/市榜',
              icon: Icons.emoji_events_outlined,
              color: AppPalette.primaryAccent,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const LeaderboardPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '拍照识题',
              subtitle: '相册识题',
              icon: Icons.document_scanner_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PhotoQuestionPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '我的成长',
              subtitle: '年级资料',
              icon: Icons.person_outline,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const StudentProfileEditPage(),
                    ),
                  ),
            ),
          ],
        ),
      ],
    );
  }
}
