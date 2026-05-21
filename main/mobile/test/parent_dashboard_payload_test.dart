import 'package:flutter_test/flutter_test.dart';

import 'package:ai_feynman/data/parent_models.dart';

void main() {
  test('parent dashboard payload parses round11 fields compatibly', () {
    final payload = ParentDashboardPayload.fromJson({
      'studentName': '小太阳',
      'grade': '八年级',
      'overallMastery': 72,
      'practicedSections': 2,
      'completedRounds': 4,
      'weakSections': const [],
      'strongSections': const [],
      'recentReviews': const [],
      'suggestedNextAction': '继续挑战',
      'serverTime': '2026-05-22T00:00:00',
    });
    expect(payload.studentName, '小太阳');
    expect(payload.overallMastery, 72);
  });
}
