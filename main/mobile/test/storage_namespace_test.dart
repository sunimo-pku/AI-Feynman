import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_feynman/services/progress_repository.dart';
import 'package:ai_feynman/services/review_repository.dart';

void main() {
  test('progress and review are isolated by namespace', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProgressRepository.instance.testPrefsOverride = prefs;
    ReviewRepository.instance.testPrefsOverride = prefs;

    await ProgressRepository.instance.switchUser('userA');
    await ProgressRepository.instance.applyCompleted(
      sectionId: 'pep-g8-down-s16-3',
      masteryDelta: 1,
      summary: 'A',
    );
    expect(ProgressRepository.instance.progressFor('pep-g8-down-s16-3').masteryScore, 10);

    await ProgressRepository.instance.switchUser('userB');
    expect(ProgressRepository.instance.progressFor('pep-g8-down-s16-3').masteryScore, 0);

    await ProgressRepository.instance.switchUser('userA');
    expect(ProgressRepository.instance.progressFor('pep-g8-down-s16-3').masteryScore, 10);
  });
}
