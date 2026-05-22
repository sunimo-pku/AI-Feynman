import 'package:flutter/material.dart';

import '../data/round12_models.dart';
import '../theme/app_theme.dart';
import 'formula_text.dart';

/// 每日挑战：逐步选择题（紧凑横条，非大矩形面板）。
class BountyStepQuizBar extends StatelessWidget {
  const BountyStepQuizBar({
    super.key,
    required this.quizzes,
    required this.currentIndex,
    required this.answers,
    required this.onPick,
    required this.onPrev,
    required this.onNext,
  });

  final List<BountyStepQuiz> quizzes;
  final int currentIndex;
  final Map<String, String> answers;
  final void Function(String stepId, String optionId) onPick;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    if (quizzes.isEmpty) {
      return const SizedBox.shrink();
    }
    final idx = currentIndex.clamp(0, quizzes.length - 1);
    final quiz = quizzes[idx];
    final picked = answers[quiz.stepId];

    return Material(
      color: AppPalette.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.primary.withValues(alpha: 0.2)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '逐步找错 ${idx + 1}/${quizzes.length}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppPalette.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: idx > 0 ? onPrev : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: idx < quizzes.length - 1 ? onNext : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            FormulaText(
              quiz.statement,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final opt in quiz.options)
                  _OptionOrb(
                    label: opt.label,
                    selected: picked == opt.optionId,
                    onTap: () => onPick(quiz.stepId, opt.optionId),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionOrb extends StatelessWidget {
  const _OptionOrb({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppPalette.primary : AppPalette.textSecondary;
    return Material(
      color: selected
          ? AppPalette.primary.withValues(alpha: 0.12)
          : AppPalette.background,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
