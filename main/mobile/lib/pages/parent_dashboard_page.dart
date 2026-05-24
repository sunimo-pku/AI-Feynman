import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_branding.dart';
import '../data/parent_models.dart';
import '../data/question_engagement_models.dart';
import '../data/round12_models.dart';
import '../services/auth_service.dart';
import '../services/learning_sync_service.dart';
import '../services/parent_service.dart';
import '../services/replay_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'replay_page.dart';

const List<String> _gradeOptions = <String>['七年级', '八年级', '九年级'];

/// 家长端 dashboard 页（第十轮）。
///
/// 入口：首页 AppBar「家长端」按钮。
///
/// 责任：
///   * 进入时先确保已登录；未登录跳 AuthPage；
///   * 触发一次本地 → 后端同步，让 dashboard 拿到最新数据；
///   * 拉 `/parent/dashboard`，展示：
///     - 学生姓名 + 总体掌握度 + 已练章节数 / 总轮数；
///     - 弱项卡片：分数 + 一句话 reason；
///     - 优势项；
///     - 最近讲题回顾（FormulaText 渲染题面与摘要）；
///     - 教师建议下一步；
///     - 一键「查看本周总结海报」（PosterSheet）。
///
/// 风格遵循 `MOBILE_STYLE.md`：温和、可信、面向家长，不上电竞配色。
class ParentDashboardPage extends StatefulWidget {
  const ParentDashboardPage({super.key, this.embedded = false});

  /// 家长账号登录后作为 App 根页面展示，退出登录不切 Navigator.pop。
  final bool embedded;

  @override
  State<ParentDashboardPage> createState() => _ParentDashboardPageState();
}

class _ParentDashboardPageState extends State<ParentDashboardPage> {
  final ParentService _parentService = ParentService();
  final ReplayService _replayService = ReplayService();

  bool _loading = true;
  String? _error;
  ParentDashboardPayload? _payload;
  List<ReplaySummary> _replays = const <ReplaySummary>[];
  List<ParentQuestionFeedbackItem> _questionFeedback =
      const <ParentQuestionFeedbackItem>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await AuthService.instance.load();
    if (!mounted) return;
    if (!AuthService.instance.isLoggedIn || !AuthService.instance.isParent) {
      if (widget.embedded) {
        await AuthService.instance.logout();
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    await _refresh(forceSync: false);
  }

  Future<void> _refresh({bool forceSync = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (forceSync) {
      // 家长端不同步本地进度；刷新仅重拉服务端数据。
    }
    try {
      final payload = await _parentService.fetchDashboard();
      final replays = await _replayService.fetchParentReplays();
      final feedback = await _parentService.fetchQuestionFeedback();
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _replays = replays;
        _questionFeedback = feedback;
        _loading = false;
      });
    } on ParentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
      if (e.statusCode == 401) {
        await AuthService.instance.logout();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _parentService.close();
    _replayService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: _payload?.studentName.isNotEmpty == true
          ? '${_payload!.studentName}的学习记录'
          : '学习记录',
      maxWidth: 1180,
      actions: [
        IconButton(
          tooltip: '生成本周小结',
          icon: const Icon(Icons.auto_stories_outlined),
          onPressed: () => _showPoster(context),
        ),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : () => _refresh(forceSync: true),
        ),
        Builder(
          builder:
              (innerCtx) => PopupMenuButton<String>(
                onSelected: (key) async {
                  if (key == 'logout') {
                    await AuthService.instance.logout();
                    if (!mounted) return;
                    if (!widget.embedded) {
                      Navigator.of(innerCtx).pop();
                    }
                  } else if (key == 'switch_student') {
                    final messenger = ScaffoldMessenger.of(innerCtx);
                    final result = await AuthService.instance.switchToStudent();
                    if (!innerCtx.mounted) return;
                    if (!result.ok) {
                      messenger.showSnackBar(
                        SnackBar(content: Text(result.message)),
                      );
                      return;
                    }
                    unawaited(LearningSyncService.instance.pullAndMerge());
                  } else if (key == 'edit_profile') {
                    await _editProfile(innerCtx);
                  }
                },
                itemBuilder:
                    (_) => const [
                      PopupMenuItem(
                        value: 'switch_student',
                        child: Text('切换到学生端'),
                      ),
                      PopupMenuItem(
                        value: 'edit_profile',
                        child: Text('编辑孩子资料'),
                      ),
                      PopupMenuItem(value: 'logout', child: Text('退出登录')),
                    ],
              ),
        ),
      ],
      child: _buildBody(context),
    );
  }

  Future<void> _editProfile(BuildContext context) async {
    final payload = _payload;
    final nameController = TextEditingController(
      text: payload?.studentName ?? '',
    );
    final gradeController = TextEditingController(
      text: payload?.grade ?? '八年级',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('编辑孩子资料'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '展示名'),
                ),
                DropdownButtonFormField<String>(
                  initialValue:
                      _gradeOptions.contains(gradeController.text)
                          ? gradeController.text
                          : '八年级',
                  decoration: const InputDecoration(labelText: '年级'),
                  items:
                      _gradeOptions
                          .map(
                            (grade) => DropdownMenuItem(
                              value: grade,
                              child: Text(grade),
                            ),
                          )
                          .toList(),
                  onChanged:
                      (value) =>
                          gradeController.text = value ?? gradeController.text,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await _parentService.updateProfile(
      displayName: nameController.text.trim(),
      grade: gradeController.text.trim(),
    );
    if (!mounted) return;
    await _refresh();
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _payload == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _payload == null) {
      return _ErrorView(
        message: _error!,
        onRetry: () => _refresh(forceSync: true),
      );
    }
    final p = _payload!;
    return RefreshIndicator(
      onRefresh: () => _refresh(forceSync: true),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          _StudentHeaderCard(payload: p),
          const SizedBox(height: AppSpacing.sectionGap),
          _WeeklyHeatmapCard(activity: p.weeklyActivity),
          const SizedBox(height: AppSpacing.moduleGap),
          StudyInlineBanner(
            message: p.suggestedNextAction.isEmpty
                ? '继续保持每日讲题节奏，同伴们会在旁边听。'
                : p.suggestedNextAction,
            tone: StudyPanelTone.accent,
            icon: Icons.lightbulb_outline,
          ),
          const SizedBox(height: AppSpacing.moduleGap),
          _DashboardPair(
            left: _SectionGroupCard(
              title: '最近常卡',
              subtitle: '这些章节可以多讲一轮',
              color: AppPalette.error,
              sections: p.weakSections,
              emptyText: '目前没有特别薄弱的章节，继续保持。',
            ),
            right: _SectionGroupCard(
              title: '已经讲顺',
              subtitle: '孩子对这些章节比较熟',
              color: AppPalette.primaryAccent,
              sections: p.strongSections,
              emptyText: '多讲几轮后，熟练的章节会出现在这里。',
            ),
          ),
          const SizedBox(height: AppSpacing.moduleGap),
          _ReplayListCard(replays: _replays),
          const SizedBox(height: AppSpacing.moduleGap),
          _QuestionFeedbackCard(items: _questionFeedback),
          const SizedBox(height: AppSpacing.moduleGap),
          _RecentReviewsCard(reviews: p.recentReviews),
          const SizedBox(height: AppSpacing.moduleGap),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppPalette.error.withValues(alpha: 0.08),
                borderRadius: AppRadius.buttonR,
                border: Border.all(
                  color: AppPalette.error.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: AppPalette.error),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showPoster(BuildContext context) async {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppPalette.background,
      builder: (_) => _PosterSheet(parentService: _parentService),
    );
  }
}

// ---------------------------------------------------------------- widgets ----

class _DashboardPair extends StatelessWidget {
  const _DashboardPair({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              left,
              const SizedBox(height: AppSpacing.moduleGap),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: AppSpacing.moduleGap),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _StudentHeaderCard extends StatelessWidget {
  const _StudentHeaderCard({required this.payload});
  final ParentDashboardPayload payload;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      tone: StudyPanelTone.surface,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppPalette.warmTint,
                child: Text(
                  payload.studentName.isNotEmpty
                      ? payload.studentName.substring(0, 1).toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: AppPalette.primary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payload.studentName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${payload.grade} · 本周练了 ${payload.practicedSections} 节 · 共 ${payload.completedRounds} 轮讲题',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (payload.overallMastery / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppPalette.primary.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation<Color>(AppPalette.primary),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '整体进度 ${payload.overallMastery}%',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyHeatmapCard extends StatelessWidget {
  const _WeeklyHeatmapCard({required this.activity});
  final List<DayActivity> activity;

  static final List<String> _weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];

  String _weekdayLabel(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      // DateTime.weekday: 1=Mon ... 7=Sun
      final idx = (dt.weekday - 1) % 7;
      return _weekdays[idx];
    } catch (_) {
      return '';
    }
  }

  Color _cellColor(int count, BuildContext context) {
    if (count <= 0) return AppPalette.primary.withValues(alpha: 0.06);
    if (count == 1) return AppPalette.primary.withValues(alpha: 0.25);
    if (count == 2) return AppPalette.primary.withValues(alpha: 0.5);
    return AppPalette.primary.withValues(alpha: 0.85);
  }

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '近 7 天讲题节奏',
            subtitle: '颜色越深表示当天完成轮数越多',
            accent: AppPalette.primary,
          ),
          const SizedBox(height: 12),
          Row(
            children: activity.map((day) {
              return Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 32,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: _cellColor(day.completedRounds, context),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppPalette.primary.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '${day.completedRounds}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: day.completedRounds > 2
                                ? Colors.white
                                : AppPalette.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _weekdayLabel(day.date),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ReplayListCard extends StatelessWidget {
  const _ReplayListCard({required this.replays});
  final List<ReplaySummary> replays;

  static String _replaySubtitle(ReplaySummary r) {
    final sec = r.durationMs <= 0 ? 0 : (r.durationMs / 1000).ceil();
    final m = sec ~/ 60;
    final s = sec % 60;
    final time = m > 0 ? '$m 分 $s 秒' : '$s 秒';
    final when = _formatTime(r.createdAt);
    return '时长 $time · $when';
  }

  static String _difficultyLabel(int d) {
    if (d >= 3) return '挑战';
    if (d >= 2) return '巩固';
    return '基础';
  }

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '精彩回放',
            subtitle: '回看孩子讲题时的笔迹与讨论',
            accent: AppPalette.primaryAccent,
          ),
          const SizedBox(height: 10),
          if (replays.isEmpty)
            const StudyEmptyHint('完成一次讲题后，回放会出现在这里')
          else
            ...replays.map(
              (r) => StudyListRow(
                title: r.sectionLabel.isNotEmpty ? r.sectionLabel : r.sectionId,
                subtitle: _replaySubtitle(r),
                trailing: StudySoftTag(
                  text: _difficultyLabel(r.difficulty),
                  accent: r.difficulty >= 3
                      ? AppPalette.error
                      : (r.difficulty >= 2
                          ? AppPalette.primaryAccent
                          : AppPalette.primary),
                ),
                onTap:
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (_) => ReplayPage(sessionId: r.sessionId),
                      ),
                    ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionGroupCard extends StatelessWidget {
  const _SectionGroupCard({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.sections,
    required this.emptyText,
  });

  final String title;
  final String subtitle;
  final Color color;
  final List<WeakSectionInfo> sections;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: title,
            subtitle: subtitle,
            accent: color,
          ),
          const SizedBox(height: 12),
          if (sections.isEmpty)
            Text(
              emptyText,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
            )
          else
            ...sections.map((s) => _SectionRow(info: s, accent: color)),
        ],
      ),
    );
  }
}

class _MiniTrendLine extends StatelessWidget {
  const _MiniTrendLine({required this.scores, required this.color});
  final List<int> scores;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (scores.length < 2) {
      return const SizedBox(height: 20);
    }
    return SizedBox(
      height: 20,
      child: CustomPaint(
        painter: _MiniTrendPainter(scores: scores, color: color),
        size: const Size(double.infinity, 20),
      ),
    );
  }
}

class _MiniTrendPainter extends CustomPainter {
  const _MiniTrendPainter({required this.scores, required this.color});
  final List<int> scores;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final count = scores.length;
    final stepX = size.width / (count - 1);

    final path = Path();
    for (int i = 0; i < count; i++) {
      final x = i * stepX;
      final y = size.height - (scores[i] / 100.0 * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 2, dotPaint);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MiniTrendPainter old) {
    return old.scores != scores || old.color != color;
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.info, required this.accent});
  final WeakSectionInfo info;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  info.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              StudySoftTag(
                text: '进度 ${info.masteryScore}%',
                accent: accent,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${info.reason}（已练 ${info.completedRounds} 轮）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (info.masteryScore / 100).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: accent.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          if (info.recentScores.length >= 2) ...[
            const SizedBox(height: 6),
            _MiniTrendLine(scores: info.recentScores, color: accent),
          ],
        ],
      ),
    );
  }
}

class _QuestionFeedbackCard extends StatelessWidget {
  const _QuestionFeedbackCard({required this.items});

  final List<ParentQuestionFeedbackItem> items;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '题目反馈',
            subtitle: '孩子在讲题时发给您的备注',
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const StudyEmptyHint('还没有题目反馈，孩子可在讲题页点反馈按钮')
          else
            ...items.map((item) => _QuestionFeedbackItem(item: item)),
        ],
      ),
    );
  }
}

class _QuestionFeedbackItem extends StatelessWidget {
  const _QuestionFeedbackItem({required this.item});

  final ParentQuestionFeedbackItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.feedback_outlined,
                size: 18,
                color: AppPalette.primaryAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.sectionLabel.isEmpty ? item.sectionId : item.sectionLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (item.createdAt != null)
                Text(
                  _formatTime(item.createdAt!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          if (item.questionPrompt.isNotEmpty) ...[
            const SizedBox(height: 6),
            FormulaText(
              item.questionPrompt,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (item.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppPalette.primaryAccent.withValues(alpha: 0.06),
                borderRadius: AppRadius.buttonR,
                border: Border.all(
                  color: AppPalette.primaryAccent.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                item.note,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecentReviewsCard extends StatelessWidget {
  const _RecentReviewsCard({required this.reviews});
  final List<ParentReviewCard> reviews;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '最近讲题',
            subtitle: '孩子最近练了哪些题',
          ),
          const SizedBox(height: 12),
          if (reviews.isEmpty)
            const StudyEmptyHint('还没有讲题记录，让孩子先选一小节讲一题吧')
          else
            ...reviews.map((r) => _ReviewItem(card: r)),
        ],
      ),
    );
  }
}

class _ReviewItem extends StatelessWidget {
  const _ReviewItem({required this.card});
  final ParentReviewCard card;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.sectionLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                _formatTime(card.completedAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 6),
          FormulaText(
            card.questionPrompt,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (card.summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            FormulaText(
              card.summary,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ],
          if (card.cautionPoints.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...card.cautionPoints.map(
              (p) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '· ',
                      style: TextStyle(color: AppPalette.primary),
                    ),
                    Expanded(
                      child: FormulaText(
                        p,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppPalette.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const Divider(height: 18, thickness: 0.5),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: AppPalette.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterSheet extends StatefulWidget {
  const _PosterSheet({required this.parentService});
  final ParentService parentService;

  @override
  State<_PosterSheet> createState() => _PosterSheetState();
}

class _PosterSheetState extends State<_PosterSheet> {
  bool _loading = true;
  String? _error;
  ParentPosterPayload? _payload;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.parentService.fetchPoster();
      if (!mounted) return;
      setState(() {
        _payload = p;
        _loading = false;
      });
    } on ParentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载海报失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppPalette.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(child: Text(_error!))
                    : _PosterCard(
                      payload: _payload!,
                      scrollController: scrollController,
                    ),
          ),
        );
      },
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.payload, required this.scrollController});

  final ParentPosterPayload payload;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppPalette.primary.withValues(alpha: 0.08),
                AppPalette.primaryAccent.withValues(alpha: 0.08),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: AppRadius.cardR,
            boxShadow: AppShadows.paper,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppBranding.displayName} · 本周学习海报',
                style: TextStyle(
                  color: AppPalette.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                payload.studentName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 2),
              Text(payload.grade, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _PosterStat(
                      label: '本周完成',
                      value: '${payload.weekCompletedRounds} 轮',
                    ),
                  ),
                  Expanded(
                    child: _PosterStat(
                      label: '最强章节',
                      value:
                          payload.highestSection.isEmpty
                              ? '—'
                              : '${payload.highestScore}/100',
                      sub:
                          payload.highestSection.isEmpty
                              ? null
                              : payload.highestSection,
                    ),
                  ),
                  Expanded(
                    child: _PosterStat(
                      label: '最需巩固',
                      value:
                          payload.weakestSection.isEmpty
                              ? '—'
                              : '${payload.weakestScore}/100',
                      sub:
                          payload.weakestSection.isEmpty
                              ? null
                              : payload.weakestSection,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '老师建议',
                style: TextStyle(
                  color: AppPalette.primaryAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                payload.teacherTip,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (payload.lastQuestionPrompt.isNotEmpty) ...[
                const SizedBox(height: 18),
                const Text(
                  '最近一次精彩讲题',
                  style: TextStyle(
                    color: AppPalette.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                FormulaText(
                  payload.lastQuestionPrompt,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (payload.lastSummary.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  FormulaText(
                    payload.lastSummary,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 18),
              Text(
                '生成时间：${_fmtDate(payload.generatedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '提示：可截图分享给家庭群（系统截屏即可）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PosterStat extends StatelessWidget {
  const _PosterStat({required this.label, required this.value, this.sub});

  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppPalette.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(
            sub!,
            style: const TextStyle(
              fontSize: 11,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

String _formatTime(DateTime when) {
  final now = DateTime.now();
  final diff = now.difference(when);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 6) return '${diff.inHours} 小时前';
  final hh = when.hour.toString().padLeft(2, '0');
  final mm = when.minute.toString().padLeft(2, '0');
  if (when.year == now.year && when.month == now.month && when.day == now.day) {
    return '今天 $hh:$mm';
  }
  return '${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')} $hh:$mm';
}

String _fmtDate(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
