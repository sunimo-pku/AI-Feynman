import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_feynman/data/progress_models.dart';
import 'package:ai_feynman/services/learning_sync_service.dart';
import 'package:ai_feynman/services/progress_repository.dart';

void main() {
  test('applyFromServer overwrites with higher server score exactly', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProgressRepository.instance.testPrefsOverride = prefs;
    await ProgressRepository.instance.switchUser('sync-user');
    await ProgressRepository.instance.applyCompleted(
      sectionId: 'pep-g8-down-s16-3',
      masteryDelta: 1,
      summary: 'local',
    );
    await ProgressRepository.instance.applyFromServer(
      SectionProgress(
        sectionId: 'pep-g8-down-s16-3',
        completedRounds: 3,
        masteryScore: 90,
        lastPracticedAt: DateTime(2026, 5, 22),
        lastSummary: 'server',
      ),
    );
    final p = ProgressRepository.instance.progressFor('pep-g8-down-s16-3');
    expect(p.masteryScore, 90);
    expect(p.completedRounds, 3);
  });

  test(
    'server payload refreshes newer summary when score and rounds are equal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ProgressRepository.instance.testPrefsOverride = prefs;
      await ProgressRepository.instance.switchUser('sync-summary-user');
      await ProgressRepository.instance.applyFromServer(
        SectionProgress(
          sectionId: 'pep-g8-down-s16-3',
          completedRounds: 2,
          masteryScore: 30,
          lastPracticedAt: DateTime(2026, 5, 22, 10),
          lastSummary: 'old summary',
        ),
      );

      await LearningSyncService.instance.applyServerPayloadForTesting({
        'progress': [
          {
            'sectionId': 'pep-g8-down-s16-3',
            'completedRounds': 2,
            'masteryScore': 30,
            'lastPracticedAt': '2026-05-22T11:00:00.000',
            'lastSummary': 'new summary',
          },
        ],
        'reviews': const [],
      });

      final p = ProgressRepository.instance.progressFor('pep-g8-down-s16-3');
      expect(p.masteryScore, 30);
      expect(p.completedRounds, 2);
      expect(p.lastSummary, 'new summary');
      expect(p.lastPracticedAt, DateTime(2026, 5, 22, 11));
    },
  );
}
