import 'package:flutter/material.dart';

import '../data/round12_models.dart';
import '../services/auth_service.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'v2_pages.dart';

/// 学生端「今日」Tab：问候 + 每日挑战主卡片 + 快捷入口。
class HomeDashboardTab extends StatefulWidget {
  const HomeDashboardTab({
    super.key,
    required this.pendingAssignments,
    required this.onAssignmentsTap,
    required this.onOpenCurriculum,
  });

  final int pendingAssignments;
  final VoidCallback onAssignmentsTap;
  final VoidCallback onOpenCurriculum;

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
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DailyChallengePage()),
    );
    if (mounted) await _loadBountySummary();
  }

  @override
  Widget build(BuildContext context) {
    final bounty = _bountyToday;
    final total = bounty?.totalCount ?? 3;
    final done = bounty?.completedCount ?? 0;
    final streak = bounty?.streakDays ?? 0;
    final todayDone = total > 0 && done >= total;

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
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                      children: [
                        Text(
                          '每日挑战',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          streak > 0
                              ? '帮同学找错 · 已连续打卡 $streak 天'
                              : '帮同学找错 · 完成今日挑战开始打卡',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppPalette.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
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
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _loadingBounty ? null : _openDailyChallenge,
                child: Text(todayDone ? '再练一遍' : '开始挑战'),
              ),
            ],
          ),
        ),
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
      ],
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
