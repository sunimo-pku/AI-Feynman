import 'dart:convert';

import 'package:ai_feynman/data/review_models.dart';
import 'package:ai_feynman/services/review_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 第八轮新增：本地讲题回顾仓库的单元测试。
///
/// 保护以下不变量（任一退化都会让首页 + 回顾页体验崩盘）：
///   * `LectureReviewRecord` encode/decode 字段完整、容错；
///   * `ReviewRepository.append` 倒序排好、上限 30 条、按 sectionId 过滤；
///   * 写盘后模拟 App 重启仍能从持久化层读出；
///   * `derivCautionPoints` 命中规则、去重、3 条上限、兜底文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LectureReviewRecord buildRecord({
    required String id,
    required String sectionId,
    required String questionId,
    DateTime? completedAt,
    List<String> tags = const ['化简', '合并同类项'],
    int difficulty = 2,
    String summary = 'summary',
    List<String> highlights = const ['highlight'],
    List<String> cautions = const ['caution'],
  }) {
    return LectureReviewRecord(
      id: id,
      sectionId: sectionId,
      questionId: questionId,
      questionPrompt: r'化简：$2\sqrt{8}+\sqrt{18}$',
      difficulty: difficulty,
      tags: tags,
      completedAt: completedAt ?? DateTime(2026, 5, 22, 0, 30),
      summary: summary,
      agentHighlights: highlights,
      cautionPoints: cautions,
    );
  }

  group('LectureReviewRecord JSON', () {
    test('round-trip encode/decode preserves all fields', () {
      final original = buildRecord(
        id: 'q-s16-3-002-123',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q-s16-3-002',
      );
      final restored = LectureReviewRecord.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.sectionId, original.sectionId);
      expect(restored.questionId, original.questionId);
      expect(restored.questionPrompt, original.questionPrompt);
      expect(restored.difficulty, original.difficulty);
      expect(restored.tags, original.tags);
      expect(restored.completedAt, original.completedAt);
      expect(restored.summary, original.summary);
      expect(restored.agentHighlights, original.agentHighlights);
      expect(restored.cautionPoints, original.cautionPoints);
    });

    test('fromJson tolerates missing / bad fields', () {
      final restored = LectureReviewRecord.fromJson(<String, dynamic>{
        'id': 'x',
        'sectionId': 'pep-g8-down-s16-1',
        'questionId': 'q-x',
        'difficulty': -99,
        'tags': null,
        'completedAt': 'not-a-date',
        'agentHighlights': ['', null, '正常一条'],
        'cautionPoints': 'not-a-list',
      });
      expect(restored.questionPrompt, '');
      expect(restored.difficulty, 1,
          reason: 'negative difficulty should clamp to 1');
      expect(restored.tags, isEmpty);
      // 解析失败时退回 now，不抛异常 —— UI 不至于因为一条脏记录崩。
      expect(restored.completedAt.isAfter(DateTime(2000)), isTrue);
      expect(restored.agentHighlights, ['正常一条'],
          reason: 'null / 空字符串应当被过滤掉');
      expect(restored.cautionPoints, isEmpty);
    });

    test('difficulty above 3 is clamped to 3', () {
      final restored = LectureReviewRecord.fromJson(<String, dynamic>{
        'id': 'x',
        'sectionId': 'x',
        'questionId': 'x',
        'difficulty': 99,
      });
      expect(restored.difficulty, 3);
    });
  });

  group('ReviewRepository', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ReviewRepository.instance.testPrefsOverride = null;
    });

    Future<ReviewRepository> freshRepo({
      Map<String, Object> initial = const <String, Object>{},
    }) async {
      SharedPreferences.setMockInitialValues(initial);
      final repo = ReviewRepository.instance;
      await repo.resetForTesting();
      await repo.load();
      return repo;
    }

    test('load with empty prefs yields empty cache', () async {
      final repo = await freshRepo();
      expect(repo.isLoaded, isTrue);
      expect(repo.allRecords, isEmpty);
      expect(repo.recordsForSection('pep-g8-down-s16-3'), isEmpty);
      expect(repo.hasRecordsForSection('pep-g8-down-s16-3'), isFalse);
    });

    test('append persists JSON and survives a simulated app restart',
        () async {
      final repo = await freshRepo();
      final record = buildRecord(
        id: 'q-s16-3-002-1',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q-s16-3-002',
      );
      await repo.append(record);
      final raw = (await SharedPreferences.getInstance())
          .getString('ai_feynman.lecture_reviews.v1.guest');
      expect(raw, isNotNull,
          reason: 'append must write the storage key');
      final decoded = jsonDecode(raw!) as List<dynamic>;
      expect(decoded.length, 1);
      expect(
        (decoded.first as Map<String, dynamic>)['questionId'],
        'q-s16-3-002',
      );

      // 模拟「App 重启」：只清掉内存缓存（**保留** prefs 持久化数据）。
      repo.resetCacheOnlyForTesting();
      await repo.load();
      expect(repo.allRecords.length, 1);
      expect(repo.recordsForSection('pep-g8-down-s16-3').length, 1);
    });

    test('records are returned in completedAt desc order', () async {
      final repo = await freshRepo();
      // 故意乱序 append，验证排序是按 completedAt 而不是写入顺序。
      await repo.append(buildRecord(
        id: 'mid',
        sectionId: 's',
        questionId: 'q-mid',
        completedAt: DateTime(2026, 5, 20),
      ));
      await repo.append(buildRecord(
        id: 'newest',
        sectionId: 's',
        questionId: 'q-new',
        completedAt: DateTime(2026, 5, 22),
      ));
      await repo.append(buildRecord(
        id: 'oldest',
        sectionId: 's',
        questionId: 'q-old',
        completedAt: DateTime(2026, 5, 18),
      ));
      final list = repo.recordsForSection('s');
      expect(list.map((r) => r.id).toList(), ['newest', 'mid', 'oldest']);
    });

    test('trims global cache to 30 newest records', () async {
      final repo = await freshRepo();
      for (var i = 0; i < 35; i++) {
        await repo.append(buildRecord(
          id: 'r-$i',
          sectionId: 's',
          questionId: 'q-$i',
          completedAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        ));
      }
      expect(repo.allRecords.length, 30,
          reason: 'global cap must be 30');
      // 最早 5 条（r-0..r-4）应被丢弃。
      expect(
        repo.allRecords.any((r) => r.id == 'r-0'),
        isFalse,
      );
      expect(
        repo.allRecords.any((r) => r.id == 'r-34'),
        isTrue,
      );
    });

    test('recordsForSection respects per-section limit (default 10)',
        () async {
      final repo = await freshRepo();
      for (var i = 0; i < 12; i++) {
        await repo.append(buildRecord(
          id: 's3-$i',
          sectionId: 'pep-g8-down-s16-3',
          questionId: 'q-$i',
          completedAt: DateTime(2026, 5, 1).add(Duration(minutes: i)),
        ));
      }
      // 默认 sectionPageLimit = 10；最新的 10 条应该出现，最早 2 条不出现。
      final list = repo.recordsForSection('pep-g8-down-s16-3');
      expect(list.length, 10);
      expect(list.first.id, 's3-11');
      expect(list.any((r) => r.id == 's3-0'), isFalse);
    });

    test('recordsForSection filters by sectionId', () async {
      final repo = await freshRepo();
      await repo.append(buildRecord(
        id: 'a',
        sectionId: 'pep-g8-down-s16-1',
        questionId: 'q1',
      ));
      await repo.append(buildRecord(
        id: 'b',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q3',
      ));
      expect(repo.recordsForSection('pep-g8-down-s16-1').length, 1);
      expect(repo.recordsForSection('pep-g8-down-s16-3').length, 1);
      expect(repo.recordsForSection('pep-g8-down-s16-2'), isEmpty);
      expect(repo.hasRecordsForSection('pep-g8-down-s16-1'), isTrue);
      expect(repo.hasRecordsForSection('pep-g8-down-s16-2'), isFalse);
    });

    test('load tolerates corrupt JSON and treats as empty', () async {
      final repo = await freshRepo(initial: <String, Object>{
        'ai_feynman.lecture_reviews.v1': '{this is not json',
      });
      expect(repo.isLoaded, isTrue);
      expect(repo.allRecords, isEmpty);
    });

    test('load tolerates non-list JSON payloads', () async {
      // 旧版本可能误把单条 record 当 object 写盘；新读取层不能崩。
      final repo = await freshRepo(initial: <String, Object>{
        'ai_feynman.lecture_reviews.v1': '{"id":"only-one"}',
      });
      expect(repo.isLoaded, isTrue);
      expect(repo.allRecords, isEmpty);
    });

    test('recordsForSection with limit<=0 returns empty', () async {
      final repo = await freshRepo();
      await repo.append(buildRecord(
        id: 'a',
        sectionId: 's',
        questionId: 'q',
      ));
      expect(repo.recordsForSection('s', limit: 0), isEmpty);
      expect(repo.recordsForSection('s', limit: -1), isEmpty);
    });
  });

  group('ReviewRepository.derivCautionPoints', () {
    test('matches 非负条件 / 取值范围', () {
      final out = ReviewRepository.derivCautionPoints(
        tags: const ['非负条件', '取值范围'],
      );
      expect(out, ['先确认表达式成立所需的取值范围。'],
          reason: '两个等价 tag 只触发一次规则');
    });

    test('matches 前提条件', () {
      final out =
          ReviewRepository.derivCautionPoints(tags: const ['前提条件']);
      expect(out, ['使用公式或法则时要补充适用条件。']);
    });

    test('matches 同类结构 / 合并同类项', () {
      final out = ReviewRepository.derivCautionPoints(
        tags: const ['同类项', '合并同类项'],
      );
      expect(out, ['先整理成同类结构，再合并系数。']);
    });

    test('matches 负号', () {
      final out = ReviewRepository.derivCautionPoints(tags: const ['负号']);
      expect(out, ['合并系数时留意减号和括号。']);
    });

    test('caps at 3 caution points', () {
      final out = ReviewRepository.derivCautionPoints(
        tags: const [
          '非负条件',
          '前提条件',
          '合并同类项',
          '负号',
        ],
      );
      expect(out.length, 3, reason: '最多保留 3 条');
      expect(out.contains('合并系数时留意减号和括号。'), isFalse,
          reason: '第 4 条规则应被裁掉');
    });

    test('fallback when no tag matches any rule', () {
      final out = ReviewRepository.derivCautionPoints(
        tags: const ['unknown-tag'],
      );
      expect(out, ['回看高亮步骤，确认每一步为什么成立。']);
    });

    test('empty tags also yield fallback', () {
      final out = ReviewRepository.derivCautionPoints(tags: const []);
      expect(out, ['回看高亮步骤，确认每一步为什么成立。']);
    });
  });
}
