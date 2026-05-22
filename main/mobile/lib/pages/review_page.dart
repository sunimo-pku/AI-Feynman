import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/mock_lecture_repository.dart';
import '../data/review_models.dart';
import '../services/review_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import 'lecture_page.dart';

/// 第八轮：单小节讲题回顾页。
///
/// 入口：首页可练习小节 pill 上的「回顾」按钮（即使尚无记录也允许进入，
/// 学生看到的是空状态文案）。
///
/// 页面分三块：
///   * AppBar：`当前小节标题 · 讲题回顾`
///   * 空状态：「完成一题后，这里会出现你的讲题小结和 AI 追问。」
///   * 记录列表（倒序）：每张卡片包含题目、难度 / 标签 chip、完成时间、本题
///     总结、AI 追问摘要、待注意点，以及一个「再讲这题」按钮。
///
/// 与 brief 第 10 节口径一致：
///   * 「再讲这题」回到 `LecturePage`，并把 `record.questionId` 传给
///     `initialQuestionId`；
///   * 若该题被题库下线 / 重命名，LecturePage 内部会回落到本节第 1 题；
///   * 不清空本地 progress 与 review。
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.section});

  final CurriculumSection section;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  @override
  void initState() {
    super.initState();
    // 首次进入时显式 load，仓库内部会复用未完成的 future，多次 push 也只
    // 读一次盘。后续写入由 ReviewRepository 自身 notifyListeners 触发 UI 刷新。
    ReviewRepository.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: Text('${widget.section.label} · 讲题回顾'),
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: ReviewRepository.instance,
          builder: (context, _) {
            final repo = ReviewRepository.instance;
            // 仓库未 load 完成时显示菊花；load 失败后 isLoaded=true、records
            // 为空 → 走空状态分支，体感与「确实还没完成过」一致。
            if (!repo.isLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            final records = repo.recordsForSection(widget.section.id);
            if (records.isEmpty) {
              return const _ReviewEmptyState();
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageEdge,
                AppSpacing.moduleGap,
                AppSpacing.pageEdge,
                AppSpacing.pageEdge,
              ),
              itemCount: records.length + 1,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.itemGap),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _ReviewHeader(
                    section: widget.section,
                    total: records.length,
                  );
                }
                final record = records[index - 1];
                return _ReviewCard(
                  record: record,
                  onReplay: () => _onReplay(record),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _onReplay(LectureReviewRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LecturePage(
          section: widget.section,
          // 命中时 LecturePage 会切到对应题；未命中（题库改动 / 老记录）时
          // 内部回落到本节第 1 题，不抛异常 —— 这是 brief 第 10 节的硬要求。
          initialQuestionId: record.questionId,
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}

class _ReviewHeader extends StatelessWidget {
  const _ReviewHeader({required this.section, required this.total});

  final CurriculumSection section;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_outlined,
                  size: 20, color: AppPalette.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${section.label} · 最近 $total 次讲题',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '回顾最近完成的题目、AI 追问的关键问题，以及下次要注意的小要点。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ReviewEmptyState extends StatelessWidget {
  const _ReviewEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_edu_outlined,
              size: 48,
              color: AppPalette.textSecondary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              '完成一题后，这里会出现你的讲题小结和 AI 追问。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '回到上一页，进入这一节的题目讲解，完成后回来看回顾。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条回顾卡片。
///
/// 排版顺序（学生从上往下扫一眼即可知道：「我做的什么题 → AI 追问 →
/// 我下次要注意什么 → 想再来一遍直接点这里」）：
///   1. 题面（含「N 分钟前 / 今天 HH:mm」时间戳与本节题号）
///   2. 难度 chip + 标签 chip（Wrap 自动换行）
///   3. 本题总结（FormulaText 渲染 LaTeX）
///   4. AI 追问摘要（最多 3 条，bullet 列表）
///   5. 待注意点（最多 3 条，warning 色 bullet）
///   6. 「再讲这题」 OutlinedButton
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.record, required this.onReplay});

  final LectureReviewRecord record;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final difficultyLabel = MockLectureRepository.instance
        .difficultyLabel(record.difficulty);
    final tags = record.tags.take(3).toList(growable: false);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle,
                  size: 18, color: AppPalette.primaryAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _formatCompletedAt(record.completedAt),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: AppPalette.primaryAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormulaText(
            record.questionPrompt,
            style: theme.textTheme.bodyLarge,
            formulaStyle: theme.textTheme.bodyLarge?.copyWith(
              color: AppPalette.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ReviewDifficultyChip(
                label: difficultyLabel,
                level: record.difficulty,
              ),
              for (final t in tags) _ReviewTagChip(label: t),
            ],
          ),
          const SizedBox(height: 14),
          const _ReviewSectionLabel(
            icon: Icons.menu_book_outlined,
            label: '本题总结',
          ),
          const SizedBox(height: 6),
          FormulaText(
            record.summary.isEmpty
                ? '本题已完成一轮讲解，建议回看高亮步骤，总结这一步为什么成立。'
                : record.summary,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textPrimary,
              height: 1.55,
            ),
            formulaStyle: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.primary,
              fontWeight: FontWeight.w700,
              height: 1.55,
            ),
          ),
          if (record.agentHighlights.isNotEmpty) ...[
            const SizedBox(height: 14),
            const _ReviewSectionLabel(
              icon: Icons.forum_outlined,
              label: 'AI 追问摘要',
            ),
            const SizedBox(height: 6),
            for (final h in record.agentHighlights)
              _ReviewBullet(text: h, color: AppPalette.primary),
          ],
          if (record.cautionPoints.isNotEmpty) ...[
            const SizedBox(height: 14),
            const _ReviewSectionLabel(
              icon: Icons.lightbulb_outline,
              label: '下次要注意',
            ),
            const SizedBox(height: 6),
            for (final c in record.cautionPoints)
              _ReviewBullet(text: c, color: AppPalette.primaryAccent),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onReplay,
              icon: const Icon(Icons.replay_outlined),
              label: const Text('再讲这题'),
            ),
          ),
        ],
      ),
    );
  }

  /// 本地时间戳格式化：
  ///   * < 1 min   → 「刚刚」
  ///   * < 60 min  → 「X 分钟前」
  ///   * 同一天     → 「今天 HH:mm」
  ///   * 同一年     → 「MM-DD HH:mm」
  ///   * 跨年       → 「YYYY-MM-DD」
  ///
  /// 故意不引入 `intl` 依赖 —— V1 边界明确「不为本地化引入重型依赖」，且
  /// 学生只在乎大致先后顺序，不需要完整本地化的相对时间字串。
  String _formatCompletedAt(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return '刚刚完成';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前完成';
    final sameDay =
        now.year == when.year && now.month == when.month && now.day == when.day;
    String two(int n) => n.toString().padLeft(2, '0');
    if (sameDay) {
      return '今天 ${two(when.hour)}:${two(when.minute)} 完成';
    }
    if (now.year == when.year) {
      return '${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)} 完成';
    }
    return '${when.year}-${two(when.month)}-${two(when.day)} 完成';
  }
}

class _ReviewSectionLabel extends StatelessWidget {
  const _ReviewSectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: AppPalette.textSecondary),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: AppPalette.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 复用样式的 bullet 行；text 可含 LaTeX 片段，统一交给 [FormulaText] 渲染。
class _ReviewBullet extends StatelessWidget {
  const _ReviewBullet({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: FormulaText(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textPrimary,
                height: 1.55,
              ),
              formulaStyle: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 回顾卡难度 chip：与讲题页 `_DifficultyChip` 视觉一致但**故意**单独写一份。
///
/// 跨文件复用会变成隐性公共契约：将来讲题页想加 hover / press 动效，回顾
/// 卡未必想跟着改；保持各自私有反而能各自演进。
class _ReviewDifficultyChip extends StatelessWidget {
  const _ReviewDifficultyChip({required this.label, required this.level});

  final String label;
  final int level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      3 => AppPalette.error,
      2 => AppPalette.primary,
      _ => AppPalette.primaryAccent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ReviewTagChip extends StatelessWidget {
  const _ReviewTagChip({required this.label});

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
