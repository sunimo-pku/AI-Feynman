import 'package:flutter/material.dart';

import '../data/review_models.dart';
import '../data/round12_models.dart';
import '../services/auth_service.dart';
import '../services/review_repository.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'v2_pages.dart';

/// 学生端「今日」Tab：问候 + 每日挑战主卡片 + 最近回顾 + 快捷入口。
class HomeDashboardTab extends StatefulWidget {
  const HomeDashboardTab({
    super.key,
    required this.pendingAssignments,
    required this.onAssignmentsTap,
    required this.onOpenCurriculum,
    required this.onOpenReview,
  });

  final int pendingAssignments;
  final VoidCallback onAssignmentsTap;
  final VoidCallback onOpenCurriculum;
  final void Function(String sectionId) onOpenReview;

  @override
  State<HomeDashboardTab> createState() => _HomeDashboardTabState();
}

class _HomeDashboardTabState extends State<HomeDashboardTab> {
  final Round12Service _bountyService = Round12Service();
  BountyToday? _bountyToday;
  bool _loadingBounty = true;

  @override
  void initState() {
    super.initState();
    _loadBountySummary();
  }

  @override
  void dispose() {
    _bountyService.close();
    super.dispose();
  }

  Future<void> _loadBountySummary() async {
    if (!AuthService.instance.isLoggedIn) {
      if (mounted) setState(() => _loadingBounty = false);
      return;
    }
    setState(() => _loadingBounty = true);
    try {
      final today = await _bountyService.fetchBountyToday();
      if (!mounted) return;
      setState(() {
        _bountyToday = today;
        _loadingBounty = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingBounty = false);
    }
  }

  Future<void> _openDailyChallenge() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DailyChallengePage()));
    if (mounted) await _loadBountySummary();
  }

  @override
  Widget build(BuildContext context) {
    final bounty = _bountyToday;
    final total = bounty?.totalCount ?? 3;
    final done = bounty?.completedCount ?? 0;
    final streak = bounty?.streakDays ?? 0;
    final todayDone = total > 0 && done >= total;

    return AnimatedBuilder(
      animation: ReviewRepository.instance,
      builder: (context, _) {
        final recentRecords = ReviewRepository.instance.allRecords;
        final hasRecent = recentRecords.isNotEmpty;
        final firstRecent = hasRecent ? recentRecords.first : null;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageEdge,
            12,
            AppSpacing.pageEdge,
            24,
          ),
          children: [
            const _CompactGreeting(),
            if (widget.pendingAssignments > 0) ...[
              const SizedBox(height: 10),
              _PendingAssignmentsBanner(
                count: widget.pendingAssignments,
                onTap: widget.onAssignmentsTap,
              ),
            ],
            const SizedBox(height: 14),
            StudyPanel(
              tone: StudyPanelTone.accent,
              padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppPalette.primaryAccent.withValues(alpha: 0.14),
                      borderRadius: AppRadius.buttonR,
                    ),
                    child: const Icon(
                      Icons.edit_outlined,
                      color: AppPalette.primaryAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '每日挑战',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          streak > 0
                              ? '帮同学找错 · 已连续打卡 $streak 天'
                              : '帮同学找错 · 完成今日挑战开始打卡',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color: AppPalette.textSecondary,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            StudySoftTag(
                              text:
                                  _loadingBounty
                                      ? '加载今日进度…'
                                      : '今日 $done / $total 题',
                              accent: AppPalette.primary,
                            ),
                            if (!_loadingBounty && todayDone)
                              const StudySoftTag(
                                text: '今日已打卡',
                                accent: AppPalette.primaryAccent,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      minimumSize: const Size(0, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _loadingBounty ? null : _openDailyChallenge,
                    child: Text(todayDone ? '再练一遍' : '开始挑战'),
                  ),
                ],
              ),
            ),
            if (hasRecent && firstRecent != null) ...[
              const SizedBox(height: 16),
              const StudySectionTitle(title: '最近回顾'),
              const SizedBox(height: 10),
              _RecentReviewCard(
                record: firstRecent,
                onTap: () => widget.onOpenReview(firstRecent.sectionId),
              ),
            ],
            const SizedBox(height: 16),
            const StudySectionTitle(title: '快捷入口'),
            StudyToolGrid(
              cells: [
                StudyToolCell(
                  label: '选课讲题',
                  subtitle: '按章节开练',
                  icon: Icons.menu_book_outlined,
                  color: AppPalette.primary,
                  onTap: widget.onOpenCurriculum,
                ),
                StudyToolCell(
                  label: '我的作业',
                  subtitle: '家长布置的',
                  icon: Icons.description_outlined,
                  onTap: widget.onAssignmentsTap,
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
                  label: '拍照识题',
                  subtitle: '拍照或相册',
                  icon: Icons.document_scanner_outlined,
                  color: AppPalette.primaryAccent,
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
      },
    );
  }
}

/// 首页「最近回顾」紧凑卡片。
///
/// 只展示最核心的信息：题面、难度标签、完成时间，
/// 点击直达该小节的 [ReviewPage]。
class _RecentReviewCard extends StatelessWidget {
  const _RecentReviewCard({required this.record, required this.onTap});

  final LectureReviewRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: AppPalette.surface,
      borderRadius: AppRadius.cardR,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.cardR,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            boxShadow: AppShadows.paper,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.history_edu_outlined,
                    size: 18,
                    color: AppPalette.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _formatCompletedAt(record.completedAt),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: AppPalette.textSecondary,
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
              const SizedBox(height: 8),
              FormulaText(
                record.questionPrompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
                formulaStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: AppPalette.primary,
                  fontWeight: FontWeight.w700,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (record.tags.isNotEmpty)
                    _ReviewMetaChip(label: record.tags.first),
                  _ReviewMetaChip(
                    label: '${record.agentHighlights.length} 条追问',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCompletedAt(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return '刚刚完成';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    final sameDay =
        now.year == when.year && now.month == when.month && now.day == when.day;
    String two(int n) => n.toString().padLeft(2, '0');
    if (sameDay) return '今天 ${two(when.hour)}:${two(when.minute)}';
    if (now.year == when.year) {
      return '${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
    }
    return '${when.year}-${two(when.month)}-${two(when.day)}';
  }
}

class _ReviewMetaChip extends StatelessWidget {
  const _ReviewMetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const color = AppPalette.primaryAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
  const _CompactGreeting();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        final name = AuthService.instance.currentUsername;
        final who = name.isEmpty ? '同学' : name;
        return Text(
          '${_timeGreeting()}，$who',
          style: Theme.of(context).textTheme.headlineSmall,
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
