import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'daily_challenge_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端「更多」Tab：学习工具与扩展功能。
class MoreTabPage extends StatelessWidget {
  const MoreTabPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tools = <_MoreTool>[
      _MoreTool(
        '我的作业',
        '查看家长布置与截止',
        Icons.assignment_outlined,
        () => const StudentAssignmentsPage(),
      ),
      _MoreTool(
        '每日挑战',
        '错题分步选择 + 白板讲解',
        Icons.where_to_vote_outlined,
        () => const DailyChallengePage(),
      ),
      _MoreTool(
        '晶石奖励',
        '兑换画笔皮肤等',
        Icons.diamond_outlined,
        () => const ShopPage(),
      ),
      _MoreTool(
        '学习榜单',
        '班级 / 章节周榜',
        Icons.emoji_events_outlined,
        () => const LeaderboardPage(),
      ),
      _MoreTool(
        '拍照识题',
        '识别后跳转对应章节',
        Icons.document_scanner_outlined,
        () => const PhotoQuestionPage(),
      ),
      _MoreTool(
        '我的成长',
        '编辑年级与展示资料',
        Icons.person_outline,
        () => const StudentProfileEditPage(),
      ),
    ];

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
          '挑战、奖励与辅助功能在此；年级仅在「我的」→ 编辑资料中修改。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        ...tools.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MoreToolTile(tool: t),
          ),
        ),
      ],
    );
  }
}

class _MoreTool {
  const _MoreTool(this.title, this.subtitle, this.icon, this.builder);
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() builder;
}

class _MoreToolTile extends StatelessWidget {
  const _MoreToolTile({required this.tool});

  final _MoreTool tool;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surface,
      borderRadius: AppRadius.cardR,
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap:
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => tool.builder())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppPalette.outlineSoft),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppPalette.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(tool.icon, color: AppPalette.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tool.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tool.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
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
