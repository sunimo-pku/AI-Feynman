import 'package:ai_feynman/data/lecture_models.dart';
import 'package:ai_feynman/data/mock_lecture_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第七轮新增：本地小题库与下一题轮换的单元测试。
///
/// 保护以下不变量（任一退化都会让讲题页 UI 体验崩盘）：
///   * 16.1 / 16.2 / 16.3 每节恰好 3 道题；
///   * 难度 1-3 各占 1 道，难度从易到难依序排列；
///   * 每道题带 1-3 个 tags、有 questionId / sectionId / sectionLabel；
///   * `questionForSection(...)` 默认返回第 1 题；
///   * `index` 任意整数都能 modulo 循环到合法题目，不抛异常；
///   * `difficultyLabel` 把 1/2/3 翻译成「基础/巩固/挑战」，未知值兜底「基础」；
///   * 未知 sectionId 生成该 section 自己的通用模板题；
///   * `questionCountForSection` 对未知 section 返回 1 个通用模板题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final repo = MockLectureRepository.instance;

  setUpAll(() async {
    await repo.loadAssetBank();
  });

  const sections = <String>[
    'pep-g8-down-s16-1',
    'pep-g8-down-s16-2',
    'pep-g8-down-s16-3',
  ];

  group('MockLectureRepository · 题库结构', () {
    test('每个 V1 章节恰好 3 道题', () {
      for (final s in sections) {
        expect(
          repo.questionCountForSection(s),
          3,
          reason: '$s 应当有 3 道题',
        );
        expect(
          repo.questionsForSection(s).length,
          3,
          reason: '$s questionsForSection 长度应为 3',
        );
      }
    });

    test('每节难度按 1 / 2 / 3 升序排列', () {
      for (final s in sections) {
        final qs = repo.questionsForSection(s);
        expect(qs.map((q) => q.difficulty).toList(), [1, 2, 3],
            reason: '$s 难度应按基础→巩固→挑战排列');
      }
    });

    test('每道题字段齐全且 tags 数量在 1-3 之间', () {
      for (final s in sections) {
        for (final q in repo.questionsForSection(s)) {
          expect(q.questionId, isNotEmpty);
          expect(q.sectionId, s);
          expect(q.sectionLabel, isNotEmpty);
          expect(q.prompt, isNotEmpty);
          expect(q.hint, isNotEmpty);
          expect(q.referenceSteps, isNotEmpty);
          expect(q.tags.length, inInclusiveRange(1, 3),
              reason: '${q.questionId} 标签数量应在 1-3 之间');
          expect(q.difficulty, inInclusiveRange(1, 3));
        }
      }
    });

    test('全部 questionId 在题库内唯一', () {
      final all = <String>[];
      for (final s in sections) {
        all.addAll(repo.questionsForSection(s).map((q) => q.questionId));
      }
      final unique = all.toSet();
      expect(unique.length, all.length,
          reason: 'questionId 应当全局唯一');
    });
  });

  group('MockLectureRepository · 取题', () {
    test('questionForSection 默认返回第 1 题', () {
      for (final s in sections) {
        final defaultQ = repo.questionForSection(s);
        final firstQ = repo.questionForSection(s, index: 0);
        expect(defaultQ.questionId, firstQ.questionId);
        expect(defaultQ.difficulty, 1,
            reason: '默认 / index=0 应取基础题');
      }
    });

    test('index 超出范围按 modulo 循环', () {
      for (final s in sections) {
        final list = repo.questionsForSection(s);
        for (var i = 0; i < 10; i++) {
          final q = repo.questionForSection(s, index: i);
          expect(q.questionId, list[i % list.length].questionId,
              reason: '$s index=$i 应循环到第 ${i % list.length} 题');
        }
      }
    });

    test('负 index 也能 modulo 循环（不抛异常）', () {
      // Dart 的 % 对负数返回非负余数，所以 -1 % 3 == 2。
      for (final s in sections) {
        final list = repo.questionsForSection(s);
        final q = repo.questionForSection(s, index: -1);
        expect(q.questionId, list[2].questionId);
        final q2 = repo.questionForSection(s, index: -4);
        expect(q2.questionId, list[2].questionId);
      }
    });

    test('未知 sectionId 生成教研中模板题', () {
      final fallback = repo.questionForSection('not-a-real-section');
      expect(fallback.sectionId, 'not-a-real-section');
      expect(fallback.tags, contains('全册题库'));
    });

    test('questionCountForSection 对未知 section 返回 1 个模板题', () {
      expect(repo.questionCountForSection('not-a-real-section'), 1);
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

  group('题面契约 · 第七轮 brief 5.2 节', () {
    test('16.1 三道题用到的题面关键短语都出现', () {
      final qs = repo.questionsForSection('pep-g8-down-s16-1');
      expect(qs[0].prompt, contains(r'\sqrt{2x-6}'));
      expect(qs[1].prompt, contains(r'\sqrt{5-x}'));
      expect(qs[2].prompt, contains(r'\sqrt{x+3}'));
      expect(qs[2].prompt, contains(r'\sqrt{2-x}'));
    });

    test('16.2 三道题覆盖乘法 / 除法 / 完全平方', () {
      final qs = repo.questionsForSection('pep-g8-down-s16-2');
      expect(qs[0].prompt, contains(r'\sqrt{12}'));
      expect(qs[0].prompt, contains(r'\sqrt{3}'));
      expect(qs[1].prompt, contains(r'\sqrt{50}'));
      expect(qs[1].prompt, contains(r'\sqrt{2}'));
      expect(qs[2].prompt, contains(r'\sqrt{8}'));
      expect(qs[2].prompt, contains(r'\sqrt{18}'));
    });

    test('16.3 三道题覆盖单项 / 系数 / 多项合并', () {
      final qs = repo.questionsForSection('pep-g8-down-s16-3');
      expect(qs[0].prompt, contains(r'\sqrt{12}'));
      expect(qs[0].prompt, contains(r'\sqrt{27}'));
      expect(qs[1].prompt, contains(r'2\sqrt{8}'));
      expect(qs[1].prompt, contains(r'\sqrt{18}'));
      expect(qs[2].prompt, contains(r'\sqrt{45}'));
      expect(qs[2].prompt, contains(r'\sqrt{20}'));
      expect(qs[2].prompt, contains(r'\sqrt{5}'));
    });
  });

  group('MockLectureRepository · 知识点', () {
    test('每节 3 道题对应 3 个 knowledgePointId', () {
      for (final s in sections) {
        final qs = repo.questionsForSection(s);
        final kpIds = qs.map((q) => q.knowledgePointId).toSet();
        expect(kpIds.length, 3, reason: '$s 应有 3 个知识点题目');
        for (final q in qs) {
          expect(q.knowledgePointId, isNotEmpty);
          expect(q.knowledgePointLabel, isNotEmpty);
        }
      }
    });

    test('questionsForKnowledgePoint 只返回该知识点下的题', () {
      final qs = repo.questionsForSection('pep-g8-down-s16-1');
      final kpId = qs.first.knowledgePointId;
      final scoped = repo.questionsForKnowledgePoint(kpId);
      expect(scoped.length, greaterThanOrEqualTo(2));
      expect(scoped.first.knowledgePointId, kpId);
      expect(repo.questionCountForKnowledgePoint(kpId), scoped.length);
    });

    test('initialIndexForKnowledgePoint 随星级升高选题难度', () {
      final kpId = repo.questionsForSection('pep-g8-down-s16-1').first.knowledgePointId;
      final list = repo.questionsForKnowledgePoint(kpId);
      expect(repo.initialIndexForKnowledgePoint(list, 0), 0);
      expect(list[repo.initialIndexForKnowledgePoint(list, 0)].difficulty, 1);
      final highIdx = repo.initialIndexForKnowledgePoint(list, 5);
      expect(list[highIdx].difficulty, 3);
    });
  });

  group('LectureQuestion 模型', () {
    test('默认 difficulty=1, tags 为空', () {
      // 没有传 difficulty / tags 时仍可构造（第六轮以前的兼容路径）。
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
      for (final s in ['pep-g7-up-s4-1', 'pep-g7-up-s4-2', 'pep-g8-down-s20-1']) {
        for (final q in repo.questionsForSection(s)) {
          if (q.image != null && q.image!.asset.endsWith('.svg')) {
            withImage++;
          }
        }
      }
      expect(withImage, greaterThanOrEqualTo(4),
          reason: '带图题应能从 asset JSON 解析出 image.asset');
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
  });
}
