import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'v2_pages.dart';

/// 学生端「工具」Tab：学习辅助与系统功能。
///
/// 设计原则：
///   * 不重复首页已出现的高频入口（每日挑战、作业、商城、榜单）。
///   * 只放「低频但必要」或「首页放不下」的辅助功能。
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
          '工具箱',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          '低频辅助功能，高频入口在「今日」。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: AppSpacing.moduleGap),
        StudyToolGrid(
          cells: [
            StudyToolCell(
              label: '拍照识题',
              subtitle: '拍照或相册识题',
              icon: Icons.document_scanner_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PhotoQuestionPage(),
                    ),
                  ),
            ),
          ],
        ),
      ],
    );
  }
}
