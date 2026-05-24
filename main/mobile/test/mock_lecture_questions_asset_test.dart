import 'dart:convert';

import 'package:ai_feynman/data/mock_lecture_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'question asset covers curriculum sections; seed 3×102 + curated 16.x imports',
    () async {
      final raw = await rootBundle.loadString(
        MockLectureRepository.questionBankAssetPath,
      );
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final rawQuestions = decoded['questions'] as List<dynamic>;
      final questions = rawQuestions
          .whereType<Map<String, dynamic>>()
          .where((q) {
            final id = q['questionId'] as String? ?? '';
            return !id.endsWith('-d2') && !id.endsWith('-d3');
          })
          .toList(growable: false);
      final sectionIds =
          questions
              .map((q) => q['sectionId'] as String? ?? '')
              .where((id) => id.isNotEmpty)
              .toSet();
      // 16.3 尚未导入 curated 题，题库暂不含该节。
      expect(sectionIds.length, 101);
      expect(sectionIds.contains('pep-g8-down-s16-3'), isFalse);
      expect(questions.length, 321);

      const curatedSections = <String>{
        'pep-g8-down-s16-1',
        'pep-g8-down-s16-2',
      };
      const curatedCounts = <String, int>{
        'pep-g8-down-s16-1': 7,
        'pep-g8-down-s16-2': 17,
      };

      for (final sectionId in sectionIds) {
        final sectionQuestions = questions
            .where((q) => q['sectionId'] == sectionId)
            .toList(growable: false);
        if (curatedSections.contains(sectionId)) {
          expect(sectionQuestions.length, curatedCounts[sectionId]);
          continue;
        }
        expect(sectionQuestions.map((q) => q['difficulty']).toList(), [
          1,
          2,
          3,
        ]);
      }
    },
  );

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
