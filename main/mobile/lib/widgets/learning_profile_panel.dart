import 'package:flutter/material.dart';

import '../data/learning_profile_models.dart';
import '../theme/app_theme.dart';
import 'study_layout.dart';

class LearningProfilePanel extends StatelessWidget {
  const LearningProfilePanel({
    super.key,
    required this.profile,
    this.compact = false,
  });

  final LearningProfilePayload profile;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final weak = profile.weakKnowledge.take(compact ? 2 : 4).toList();
    final traits = profile.learningTraits.take(compact ? 2 : 4).toList();
    final actions = profile.nextActions.take(compact ? 2 : 4).toList();
    final sourceLabel =
        profile.profileSource == 'rules_ai' ? '规则证据 + AI老师提炼' : '规则证据生成';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudyPanel(
          tone: StudyPanelTone.accent,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StudyDenseTile(
                title: '长期学习画像',
                subtitle:
                    profile.dataPoints > 0
                        ? '${profile.grade} · $sourceLabel · ${profile.dataPoints} 条证据'
                        : '${profile.grade} · 样本积累中',
                icon: Icons.psychology_alt_outlined,
                accent: AppPalette.primaryAccent,
              ),
              const SizedBox(height: 6),
              Text(
                profile.overview,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textPrimary,
                  height: 1.55,
                ),
              ),
              if (profile.aiSummary.isNotEmpty) ...[
                const SizedBox(height: 10),
                StudyInlineBanner(
                  message: profile.aiSummary,
                  tone: StudyPanelTone.quiet,
                  icon: Icons.auto_awesome_outlined,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (weak.isNotEmpty) ...[
          const StudySectionTitle(
            title: '薄弱知识点',
            subtitle: '每一条都来自掌握度、错因或讲题记录。',
          ),
          StudyGroupedPanel(
            children:
                weak
                    .map(
                      (item) => _InsightTile(
                        insight: item,
                        icon: Icons.report_problem_outlined,
                        accent: AppPalette.error,
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 12),
        ],
        if (traits.isNotEmpty) ...[
          const StudySectionTitle(title: '学习特征'),
          StudyGroupedPanel(
            children:
                traits
                    .map(
                      (item) => _InsightTile(
                        insight: item,
                        icon: Icons.auto_graph_outlined,
                        accent: AppPalette.primary,
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 12),
        ],
        if (!compact && profile.strengths.isNotEmpty) ...[
          const StudySectionTitle(title: '优势章节'),
          StudyGroupedPanel(
            children:
                profile.strengths
                    .map(
                      (item) => _InsightTile(
                        insight: item,
                        icon: Icons.verified_outlined,
                        accent: AppPalette.primaryAccent,
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 12),
        ],
        if (actions.isNotEmpty) ...[
          const StudySectionTitle(title: '下一步建议'),
          StudyPanel(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < actions.length; i++)
                  _ActionLine(index: i + 1, text: actions[i]),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _InsightTile extends StatelessWidget {
  const _InsightTile({
    required this.insight,
    required this.icon,
    required this.accent,
  });

  final ProfileInsight insight;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final evidence =
        insight.evidence.isEmpty
            ? ''
            : insight.evidence
                .take(2)
                .map((e) => '${e.label}：${e.detail}')
                .join('\n');
    final subtitle =
        evidence.isEmpty ? insight.description : '${insight.description}\n$evidence';
    return StudyDenseTile(
      title: insight.title,
      subtitle: subtitle,
      icon: icon,
      accent: accent,
      dense: true,
    );
  }
}

class _ActionLine extends StatelessWidget {
  const _ActionLine({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: index == 1 ? 0 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppPalette.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              '$index',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppPalette.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
