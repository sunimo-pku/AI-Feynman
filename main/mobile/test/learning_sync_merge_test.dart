import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_feynman/data/progress_models.dart';
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
}
