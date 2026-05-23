import 'package:flutter/material.dart';

import '../config/app_branding.dart';
import '../data/curriculum_models.dart';
import '../data/knowledge_point_progress_models.dart';
import '../data/mock_lecture_repository.dart';
import '../services/knowledge_point_progress_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/knowledge_point_stars.dart';
import '../widgets/study_layout.dart';

/// 小节详情：展开为知识点列表，题目挂在知识点下。
class SectionKnowledgePage extends StatelessWidget {
  const SectionKnowledgePage({
    super.key,
    required this.section,
    required this.onKnowledgePointTap,
    required this.onSectionReview,
  });

  final CurriculumSection section;
  final void Function(CurriculumKnowledgePoint kp) onKnowledgePointTap;
  final VoidCallback onSectionReview;

  @override
  Widget build(BuildContext context) {
    final kps = section.knowledgePoints;
    final repo = MockLectureRepository.instance;

    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: Text(section.label)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          StudyPanel(
            tone: StudyPanelTone.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.label,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  kps.isEmpty
                      ? '本节题目加载中或暂无知识点划分'
                      : '${kps.length} 个知识点 · 点选开始讲题',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (kps.isEmpty)
            const StudyEmptyHint('暂无知识点，请稍后刷新或检查课程数据。')
          else
            AnimatedBuilder(
              animation: KnowledgePointProgressRepository.instance,
              builder: (context, _) {
                return StudyGroupedPanel(
                  children:
                      kps.map((kp) {
                        final count = repo.questionCountForKnowledgePoint(kp.id);
                        final stars =
                            KnowledgePointProgressRepository.instance
                                .progressFor(kp.id)
                                .stars;
                        final diffHint = difficultyForKnowledgePointStars(stars);
                        final diffLabel =
                            MockLectureRepository.instance.difficultyLabel(
                              diffHint,
                            );
                        return StudyListRow(
                          title: kp.label,
                          subtitle:
                              count > 0
                                  ? '$count 道题 · 推荐 $diffLabel · ${AppBranding.lectureEntryLabel}'
                                  : '题目整理中',
                          trailing: KnowledgePointStars(
                            stars: stars,
                            size: 14,
                            showLabel: false,
                          ),
                          onTap:
                              count > 0 ? () => onKnowledgePointTap(kp) : null,
                        );
                      }).toList(),
                );
              },
            ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onSectionReview,
            icon: const Icon(Icons.history_edu_outlined, size: 18),
            label: const Text('本节讲题回顾'),
          ),
        ],
      ),
    );
  }
}
