import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'privacy_notice_page.dart';
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
          '拍照识题、个人资料与隐私设置',
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
              subtitle: '相册或拍照识题',
              icon: Icons.document_scanner_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PhotoQuestionPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '我的资料',
              subtitle: '年级与昵称',
              icon: Icons.person_outline,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const StudentProfileEditPage(),
                    ),
                  ),
            ),
            StudyToolCell(
              label: '隐私说明',
              subtitle: '数据与权限',
              icon: Icons.privacy_tip_outlined,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PrivacyNoticePage(),
                    ),
                  ),
            ),
          ],
        ),
      ],
    );
  }
}
