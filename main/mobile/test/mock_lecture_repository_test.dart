import 'package:ai_feynman/data/lecture_models.dart';
import 'package:ai_feynman/data/mock_lecture_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第七轮新增：本地小题库与下一题轮换的单元测试。
///
/// 第十六章题库由 manual 导入维护；空库时 `questionCountForSection` 为 0，
/// `questionForSection` 回落到该节通用模板题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final repo = MockLectureRepository.instance;

  setUpAll(() async {
    await repo.loadAssetBank();
  });

  group('MockLectureRepository · 题库结构', () {
    test('16.1 已导入 curated 题（无旧 seed 001-003）', () {
      expect(repo.questionCountForSection('pep-g8-down-s16-1'), 7);
      expect(repo.questionCountForSection('pep-g8-down-s16-3'), 0);
      final ids = repo
          .questionsForSection('pep-g8-down-s16-1')
          .map((q) => q.questionId)
          .toSet();
      expect(ids.contains('q-s16-1-001'), isFalse);
      expect(ids.contains('q-s16-1-002'), isFalse);
      expect(ids.contains('q-s16-1-003'), isFalse);
      expect(
        repo.questionsForKnowledgePoint('pep-g8-down-s16-1-kp1').length,
        3,
      );
      expect(
        repo.questionsForKnowledgePoint('pep-g8-down-s16-1-kp2').length,
        4,
      );
    });

    test('16.2「二次根式的性质与化简」已导入 5 道 curated 题', () {
      expect(repo.questionCountForSection('pep-g8-down-s16-2'), 17);
      final kpQs = repo.questionsForKnowledgePoint('pep-g8-down-s16-2-kp1');
      expect(kpQs.length, 5);
      expect(kpQs.map((q) => q.difficulty).toList(), [1, 1, 2, 2, 3]);
    });

    test('16.2「最简二次根式」已导入 2 道 curated 题', () {
      final kpQs = repo.questionsForKnowledgePoint('pep-g8-down-s16-2-kp2');
      expect(kpQs.length, 2);
      expect(kpQs.map((q) => q.questionId).toSet(), {
        'q-s16-2-kp2-001',
        'q-s16-2-kp2-002',
      });
    });

    test('16.2「二次根式的乘除法」已导入 5 道 curated 题', () {
      final kpQs = repo.questionsForKnowledgePoint('pep-g8-down-s16-2-kp3');
      expect(kpQs.length, 5);
      expect(kpQs.map((q) => q.difficulty).toList(), [1, 1, 2, 2, 3]);
    });

    test('16.2「分母有理化」已导入 5 道 curated 题', () {
      final kpQs = repo.questionsForKnowledgePoint('pep-g8-down-s16-2-kp4');
      expect(kpQs.length, 5);
      expect(kpQs.map((q) => q.difficulty).toList(), [1, 1, 2, 2, 3]);
    });

    test('其它可练章节仍保留 seed 题', () {
      expect(repo.questionCountForSection('pep-g7-up-s1-1'), 3);
    });

    test('每节难度非递减排列', () {
      for (final s in ['pep-g7-up-s1-1', 'pep-g7-up-s1-2']) {
        final qs = repo.questionsForSection(s);
        final diffs = qs.map((q) => q.difficulty).toList();
        for (var i = 1; i < diffs.length; i++) {
          expect(
            diffs[i],
            greaterThanOrEqualTo(diffs[i - 1]),
            reason: '$s 难度应非递减',
          );
        }
      }
    });

    test('每道题字段齐全且 tags 数量在 1-3 之间', () {
      for (final q in repo.questionsForSection('pep-g7-up-s1-1')) {
        expect(q.questionId, isNotEmpty);
        expect(q.sectionId, 'pep-g7-up-s1-1');
        expect(q.sectionLabel, isNotEmpty);
        expect(q.prompt, isNotEmpty);
        expect(q.hint, isNotEmpty);
        expect(q.referenceSteps, isNotEmpty);
        expect(
          q.tags.length,
          inInclusiveRange(1, 3),
          reason: '${q.questionId} 标签数量应在 1-3 之间',
        );
        expect(q.difficulty, inInclusiveRange(1, 3));
      }
    });

    test('全部 questionId 在题库内唯一', () {
      final all = repo
          .questionsForSection('pep-g7-up-s1-1')
          .map((q) => q.questionId)
          .toList();
      expect(all.toSet().length, all.length, reason: 'questionId 应当全局唯一');
    });
  });

  group('MockLectureRepository · 取题', () {
    test('questionForSection 默认返回第 1 题', () {
      final defaultQ = repo.questionForSection('pep-g7-up-s1-1');
      final firstQ = repo.questionForSection('pep-g7-up-s1-1', index: 0);
      expect(defaultQ.questionId, firstQ.questionId);
      expect(defaultQ.difficulty, 1, reason: '默认 / index=0 应取基础题');
    });

    test('第十六章空库时回落模板题', () {
      expect(repo.questionCountForSection('pep-g8-down-s16-3'), 0);
      final q = repo.questionForSection('pep-g8-down-s16-3');
      expect(q.sectionId, 'pep-g8-down-s16-3');
      expect(q.tags, contains('全册题库'));
      expect(repo.questionCountForSection('pep-g8-down-s16-1'), 7);
      expect(repo.questionCountForSection('pep-g8-down-s16-2'), 17);
    });

    test('index 超出范围按 modulo 循环', () {
      final s = 'pep-g7-up-s1-1';
      final list = repo.questionsForSection(s);
      for (var i = 0; i < 10; i++) {
        final q = repo.questionForSection(s, index: i);
        expect(
          q.questionId,
          list[i % list.length].questionId,
          reason: '$s index=$i 应循环到第 ${i % list.length} 题',
        );
      }
    });

    test('负 index 也能 modulo 循环（不抛异常）', () {
      final list = repo.questionsForSection('pep-g7-up-s1-1');
      final len = list.length;
      final q = repo.questionForSection('pep-g7-up-s1-1', index: -1);
      expect(q.questionId, list[len - 1].questionId);
      final q2 = repo.questionForSection('pep-g7-up-s1-1', index: -len);
      expect(q2.questionId, list[0].questionId);
    });

    test('未知 sectionId 生成教研中模板题', () {
      final fallback = repo.questionForSection('not-a-real-section');
      expect(fallback.sectionId, 'not-a-real-section');
      expect(fallback.tags, contains('全册题库'));
    });

    test('questionCountForSection 对未知 section 返回 0', () {
      expect(repo.questionCountForSection('not-a-real-section'), 0);
    });
  });

  group('MockLectureRepository · difficultyLabel', () {
    test('把 1 / 2 / 3 翻译成中文标签', () {
      expect(repo.difficultyLabel(1), '基础');
      expect(repo.difficultyLabel(2), '巩固');
      expect(repo.difficultyLabel(3), '挑战');
    });

    test('未知值兜底到「基础」', () {
      expect(repo.difficultyLabel(0), '基础');
      expect(repo.difficultyLabel(-1), '基础');
      expect(repo.difficultyLabel(99), '基础');
    });
  });

  group('MockLectureRepository · 知识点', () {
    test('16.1 知识点已有 curated 题', () {
      expect(
        repo.questionsForKnowledgePoint('pep-g8-down-s16-1-kp1').length,
        3,
      );
      expect(
        repo.questionsForKnowledgePoint('pep-g8-down-s16-1-kp2').length,
        4,
      );
    });

    test('questionsForKnowledgePoint 只返回该知识点下的题', () {
      final qs = repo.questionsForSection('pep-g7-up-s1-1');
      final kpId = qs.first.knowledgePointId;
      final scoped = repo.questionsForKnowledgePoint(kpId);
      expect(scoped.length, greaterThanOrEqualTo(1));
      expect(scoped.first.knowledgePointId, kpId);
      expect(repo.questionCountForKnowledgePoint(kpId), scoped.length);
    });

    test('initialIndexForKnowledgePoint 随星级升高选题难度', () {
      final kpId =
          repo.questionsForSection('pep-g7-up-s1-1').first.knowledgePointId;
      final list = repo.questionsForKnowledgePoint(kpId);
      expect(repo.initialIndexForKnowledgePoint(list, 0), 0);
      expect(list[repo.initialIndexForKnowledgePoint(list, 0)].difficulty, 1);
      final highIdx = repo.initialIndexForKnowledgePoint(list, 5);
      expect(list[highIdx].difficulty, 3);
    });
  });

  group('LectureQuestion 模型', () {
    test('默认 difficulty=1, tags 为空', () {
      const q = LectureQuestion(
        questionId: 'q-test',
        sectionId: 'x',
        sectionLabel: 'x',
        prompt: '题面',
        hint: '提示',
        referenceSteps: ['s'],
      );
      expect(q.difficulty, 1);
      expect(q.tags, isEmpty);
    });

    test('几何章节题库含 SVG 配图元数据', () {
      var withImage = 0;
      for (final s in [
        'pep-g7-up-s4-1',
        'pep-g7-up-s4-2',
        'pep-g8-down-s20-1',
      ]) {
        for (final q in repo.questionsForSection(s)) {
          if (q.image != null && q.image!.asset.endsWith('.svg')) {
            withImage++;
          }
        }
      }
      expect(
        withImage,
        greaterThanOrEqualTo(4),
        reason: '带图题应能从 asset JSON 解析出 image.asset',
      );
    });

    test('fromJson 可解析可选 SVG 题图', () {
      final q = LectureQuestion.fromJson(const {
        'questionId': 'q-image',
        'sectionId': 's-image',
        'sectionLabel': '图形题',
        'prompt': '如图说明理由。',
        'hint': '提示：先读图。',
        'referenceSteps': ['读图', '推理'],
        'image': {
          'asset': 'assets/questions/diagrams/q-image.svg',
          'alt': '一张图形题配图',
        },
      });

      expect(q.image?.asset, 'assets/questions/diagrams/q-image.svg');
      expect(q.image?.alt, '一张图形题配图');
    });

    test('fromJson 可解析可选老师解答视频', () {
      final q = LectureQuestion.fromJson(const {
        'questionId': 'q-video',
        'sectionId': 's-video',
        'sectionLabel': '视频题',
        'prompt': '看完老师讲解后复述。',
        'hint': '提示：先抓关键步骤。',
        'referenceSteps': ['看视频', '复述'],
        'answerVideo': {
          'asset': 'assets/videos/answers/q-video.mp4',
          'title': '李老师完整讲解',
          'durationSeconds': 95,
        },
      });

      expect(q.answerVideo?.hasSource, isTrue);
      expect(q.answerVideo?.asset, 'assets/videos/answers/q-video.mp4');
      expect(q.answerVideo?.displayTitle, '李老师完整讲解');
      expect(q.answerVideo?.durationSeconds, 95);
    });
  });
}
