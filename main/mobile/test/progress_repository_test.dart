import 'dart:convert';

import 'package:ai_feynman/data/progress_models.dart';
import 'package:ai_feynman/services/progress_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SectionProgress JSON', () {
    test('round-trip encode/decode preserves all fields', () {
      final now = DateTime(2026, 5, 21, 23, 30);
      final original = SectionProgress(
        sectionId: 'pep-g8-down-s16-3',
        completedRounds: 2,
        masteryScore: 26,
        lastPracticedAt: now,
        lastSummary: r'能说明 \sqrt{12}=2\sqrt{3} 的拆分依据。',
      );
      final json = original.toJson();
      final restored = SectionProgress.fromJson(json);
      expect(restored.sectionId, original.sectionId);
      expect(restored.completedRounds, original.completedRounds);
      expect(restored.masteryScore, original.masteryScore);
      expect(restored.lastPracticedAt, original.lastPracticedAt);
      expect(restored.lastSummary, original.lastSummary);
    });

    test('fromJson tolerates missing / bad fields', () {
      final restored = SectionProgress.fromJson(<String, dynamic>{
        'sectionId': 'pep-g8-down-s16-1',
        'masteryScore': -5,
        'completedRounds': -3,
        'lastPracticedAt': 'not-a-date',
      });
      expect(restored.sectionId, 'pep-g8-down-s16-1');
      expect(restored.masteryScore, 0,
          reason: 'negative score must be clamped to 0');
      expect(restored.completedRounds, 0,
          reason: 'negative rounds must be clamped to 0');
      expect(restored.lastPracticedAt, isNull,
          reason: 'unparsable date should fall back to null');
      expect(restored.lastSummary, '');
    });

    test('masteryScore is clamped to 100 on parse', () {
      final restored = SectionProgress.fromJson(<String, dynamic>{
        'sectionId': 'x',
        'masteryScore': 999,
        'completedRounds': 7,
      });
      expect(restored.masteryScore, 100);
      expect(restored.completedRounds, 7);
    });
  });

  group('SectionProgress.applyCompleted', () {
    test('first completion with delta=1 yields +10', () {
      final empty = SectionProgress.empty('pep-g8-down-s16-3');
      final result = empty.applyCompleted(
        masteryDelta: 1,
        summary: '本题已讲清。',
        when: DateTime(2026, 5, 21),
      );
      expect(result.gained, 10);
      expect(result.next.masteryScore, 10);
      expect(result.next.completedRounds, 1);
      expect(result.next.lastSummary, '本题已讲清。');
    });

    test('completion with delta<=0 still grants at least 8', () {
      final empty = SectionProgress.empty('pep-g8-down-s16-3');
      final result = empty.applyCompleted(
        masteryDelta: 0,
        summary: 'fallback',
        when: DateTime(2026, 5, 21),
      );
      expect(result.gained, 8);
      expect(result.next.masteryScore, 8);

      final neg = empty.applyCompleted(
        masteryDelta: -2,
        summary: 'fallback',
        when: DateTime(2026, 5, 21),
      );
      expect(neg.gained, 8);
      expect(neg.next.masteryScore, 8);
    });

    test('masteryScore caps at 100 and gained reports actual delta', () {
      const near = SectionProgress(
        sectionId: 'pep-g8-down-s16-3',
        completedRounds: 9,
        masteryScore: 95,
      );
      final result = near.applyCompleted(
        masteryDelta: 1,
        summary: 'cap',
        when: DateTime(2026, 5, 21),
      );
      expect(result.next.masteryScore, 100);
      expect(result.gained, 5,
          reason: 'gained must reflect post-cap delta, not raw +10');
      expect(result.next.completedRounds, 10);
    });

    test('empty summary preserves previous lastSummary', () {
      const current = SectionProgress(
        sectionId: 'pep-g8-down-s16-3',
        completedRounds: 1,
        masteryScore: 10,
        lastSummary: 'previous',
      );
      final result = current.applyCompleted(
        masteryDelta: 1,
        summary: '',
        when: DateTime(2026, 5, 21),
      );
      expect(result.next.lastSummary, 'previous');
    });
  });

  group('ProgressRepository', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ProgressRepository.instance.testPrefsOverride = null;
    });

    Future<ProgressRepository> freshRepo({
      Map<String, Object> initial = const <String, Object>{},
    }) async {
      SharedPreferences.setMockInitialValues(initial);
      final repo = ProgressRepository.instance;
      await repo.resetForTesting();
      // resetForTesting clears _cache and removes key; reload to read whatever
      // mock prefs may now contain.
      // We hijack the same singleton because the production code uses
      // `ProgressRepository.instance` everywhere.
      await repo.load();
      return repo;
    }

    test('load with empty prefs yields empty progress for any sectionId',
        () async {
      final repo = await freshRepo();
      final p = repo.progressFor('pep-g8-down-s16-3');
      expect(p.completedRounds, 0);
      expect(p.masteryScore, 0);
      expect(p.hasAnyCompletion, isFalse);
    });

    test('applyCompleted persists JSON and is read back on next load',
        () async {
      final repo = await freshRepo();
      await repo.applyCompleted(
        sectionId: 'pep-g8-down-s16-3',
        masteryDelta: 1,
        summary: 'round-1 done',
      );
      final raw = (await SharedPreferences.getInstance())
          .getString('ai_feynman.section_progress.v1.guest');
      expect(raw, isNotNull,
          reason: 'applyCompleted must write the storage key');
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded.containsKey('pep-g8-down-s16-3'), isTrue);

      // 模拟「App 重启」：只清掉内存缓存（**保留** prefs 持久化数据），
      // 下一次 load() 应当从持久化层重新读出之前的进度。
      repo.resetCacheOnlyForTesting();
      await repo.load();
      final p = repo.progressFor('pep-g8-down-s16-3');
      expect(p.masteryScore, 10);
      expect(p.completedRounds, 1);
      expect(p.lastSummary, 'round-1 done');
    });

    test('multiple completions accumulate and cap at 100', () async {
      final repo = await freshRepo();
      for (var i = 0; i < 12; i++) {
        await repo.applyCompleted(
          sectionId: 'pep-g8-down-s16-3',
          masteryDelta: 1,
          summary: 'round-$i',
        );
      }
      final p = repo.progressFor('pep-g8-down-s16-3');
      expect(p.completedRounds, 12);
      expect(p.masteryScore, 100,
          reason: '12 * 10 = 120 must be clamped to 100');
    });

    test('different sectionIds are tracked independently', () async {
      final repo = await freshRepo();
      await repo.applyCompleted(
        sectionId: 'pep-g8-down-s16-1',
        masteryDelta: 1,
        summary: 's1',
      );
      await repo.applyCompleted(
        sectionId: 'pep-g8-down-s16-3',
        masteryDelta: 1,
        summary: 's3',
      );
      expect(repo.progressFor('pep-g8-down-s16-1').masteryScore, 10);
      expect(repo.progressFor('pep-g8-down-s16-3').masteryScore, 10);
      expect(repo.progressFor('pep-g8-down-s16-2').masteryScore, 0);
    });

    test('load tolerates corrupt JSON and treats as empty', () async {
      final repo = await freshRepo(initial: <String, Object>{
        'ai_feynman.section_progress.v1': '{this is not json',
      });
      // freshRepo already called load(); just assert it didn't throw and
      // cache is empty.
      expect(repo.isLoaded, isTrue);
      final p = repo.progressFor('pep-g8-down-s16-3');
      expect(p.completedRounds, 0);
      expect(p.masteryScore, 0);
    });
  });
}
