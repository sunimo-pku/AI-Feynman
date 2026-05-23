import 'package:flutter/material.dart';

import '../data/knowledge_point_progress_models.dart';
import '../theme/app_theme.dart';

/// 知识点掌握度 0–5 星展示。
class KnowledgePointStars extends StatelessWidget {
  const KnowledgePointStars({
    super.key,
    required this.stars,
    this.size = 16,
    this.showLabel = true,
  });

  final int stars;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final clamped = stars < 0
        ? 0
        : (stars > KnowledgePointProgress.maxStars
            ? KnowledgePointProgress.maxStars
            : stars);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= KnowledgePointProgress.maxStars; i++)
          Icon(
            i <= clamped ? Icons.star_rounded : Icons.star_outline_rounded,
            size: size,
            color: i <= clamped ? const Color(0xFFE6A817) : AppPalette.outline,
          ),
        if (showLabel) ...[
          const SizedBox(width: 4),
          Text(
            knowledgePointStarLabel(clamped),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
