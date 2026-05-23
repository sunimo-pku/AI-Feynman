import 'package:ai_feynman/data/knowledge_point_progress_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KnowledgePointProgress', () {
    test('completed 全员听懂 +1 或 +2 星', () {
      const p = KnowledgePointProgress(
        knowledgePointId: 'kp-1',
        stars: 1,
        completedRounds: 2,
      );
      final r1 = p.applyRound(
        status: 'completed',
        masteryDelta: 0,
        peersUnderstood: 3,
      );
      expect(r1.starGain, 1);
      expect(r1.next.stars, 2);

      final r2 = p.applyRound(
        status: 'completed',
        masteryDelta: 1,
        peersUnderstood: 3,
      );
      expect(r2.starGain, 2);
      expect(r2.next.stars, 3);
    });

    test('2/3 听懂但未 completed 仍 +1 星', () {
      const p = KnowledgePointProgress(
        knowledgePointId: 'kp-1',
        stars: 0,
        completedRounds: 0,
      );
      final r = p.applyRound(
        status: 'needs_explanation',
        masteryDelta: 0,
        peersUnderstood: 2,
      );
      expect(r.starGain, 1);
      expect(r.next.stars, 1);
    });

    test('星级上限 5', () {
      const p = KnowledgePointProgress(
        knowledgePointId: 'kp-1',
        stars: 5,
        completedRounds: 10,
      );
      final r = p.applyRound(
        status: 'completed',
        masteryDelta: 1,
        peersUnderstood: 3,
      );
      expect(r.starGain, 0);
      expect(r.next.stars, 5);
    });
  });

  group('difficultyForKnowledgePointStars', () {
    test('星级映射难度', () {
      expect(difficultyForKnowledgePointStars(0), 1);
      expect(difficultyForKnowledgePointStars(1), 1);
      expect(difficultyForKnowledgePointStars(2), 2);
      expect(difficultyForKnowledgePointStars(3), 2);
      expect(difficultyForKnowledgePointStars(4), 3);
      expect(difficultyForKnowledgePointStars(5), 3);
    });
  });
}
