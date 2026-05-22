import 'dart:convert';

import 'package:ai_feynman/data/mock_lecture_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('question asset covers 102 curriculum sections with 3 questions each', () async {
    final raw = await rootBundle.loadString(
      MockLectureRepository.questionBankAssetPath,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final questions = decoded['questions'] as List<dynamic>;
    final sectionIds = questions
        .whereType<Map<String, dynamic>>()
        .map((q) => q['sectionId'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    expect(sectionIds.length, 102);
    expect(questions.length, 306);

    for (final sectionId in sectionIds) {
      final sectionQuestions = questions
          .whereType<Map<String, dynamic>>()
          .where((q) => q['sectionId'] == sectionId)
          .toList(growable: false);
      expect(sectionQuestions.map((q) => q['difficulty']).toList(), [1, 2, 3]);
    }
  });

  test('question asset image references point to bundled SVG files', () async {
    final raw = await rootBundle.loadString(
      MockLectureRepository.questionBankAssetPath,
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final questions = decoded['questions'] as List<dynamic>;
    final imageAssets = questions
        .whereType<Map<String, dynamic>>()
        .map((q) => q['image'])
        .whereType<Map<String, dynamic>>()
        .map((image) => image['asset'] as String? ?? '')
        .where((asset) => asset.endsWith('.svg'))
        .toList(growable: false);

    expect(imageAssets, isNotEmpty);
    for (final asset in imageAssets.take(5)) {
      final svg = await rootBundle.loadString(asset);
      expect(svg, contains('<svg'));
    }
  });
}
