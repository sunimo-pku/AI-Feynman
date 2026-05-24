import 'dart:async';

import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../data/mock_lecture_repository.dart';
import '../data/question_engagement_models.dart';
import '../services/favorite_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'lecture_page.dart';

/// 「我的」Tab 内：收藏题目列表。
class FavoriteQuestionsPage extends StatefulWidget {
  const FavoriteQuestionsPage({super.key});

  @override
  State<FavoriteQuestionsPage> createState() => _FavoriteQuestionsPageState();
}

class _FavoriteQuestionsPageState extends State<FavoriteQuestionsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(FavoriteRepository.instance.load());
  }

  Future<void> _openFavorite(QuestionFavoriteItem fav) async {
    final curriculum = await CurriculumRepository.instance.load();
    CurriculumSection? section;
    for (final book in curriculum.books) {
      for (final chapter in book.chapters) {
        for (final s in chapter.sections) {
          if (s.id == fav.sectionId) {
            section = s;
            break;
          }
        }
        if (section != null) break;
      }
      if (section != null) break;
    }
    if (section == null || !mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('找不到该题所属小节，可能目录已更新。')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LecturePage(
          section: section!,
          initialQuestionId: fav.questionId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body: AnimatedBuilder(
        animation: FavoriteRepository.instance,
        builder: (context, _) {
          final favorites = FavoriteRepository.instance.favorites;
          if (favorites.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有收藏题目。\n在讲题页题面旁点星星即可收藏。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppPalette.textSecondary, height: 1.5),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            itemCount: favorites.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final fav = favorites[index];
              final level = MockLectureRepository.instance.difficultyLabel(
                fav.difficulty,
              );
              return StudyPanel(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _openFavorite(fav),
                    borderRadius: AppRadius.cardR,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.star,
                                size: 18,
                                color: AppPalette.primaryAccent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                level,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: AppPalette.primary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          FormulaText(
                            fav.questionPrompt.isEmpty
                                ? fav.questionId
                                : fav.questionPrompt,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
