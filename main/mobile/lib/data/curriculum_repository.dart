import 'dart:convert';

import 'package:flutter/services.dart';

import 'curriculum_models.dart';

class CurriculumRepository {
  CurriculumRepository._();

  static final CurriculumRepository instance = CurriculumRepository._();

  MathCurriculum? _cache;
  Map<String, String>? _sectionLabelById;

  Future<MathCurriculum> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle
        .loadString('assets/curriculum/pep-junior-math.json');
    _cache = MathCurriculum.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    return _cache!;
  }

  /// 把 `pep-g7-down-s9-2` 这类内部 id 翻成「9.2 一元一次不等式」等人读标签。
  Future<String> sectionLabelFor(String sectionId) async {
    final trimmed = sectionId.trim();
    if (trimmed.isEmpty) return sectionId;
    await _ensureSectionLabelIndex();
    return _sectionLabelById![trimmed] ?? trimmed;
  }

  Future<Map<String, String>> sectionLabelIndex() async {
    await _ensureSectionLabelIndex();
    return Map<String, String>.unmodifiable(_sectionLabelById!);
  }

  Future<void> _ensureSectionLabelIndex() async {
    if (_sectionLabelById != null) return;
    final curriculum = await load();
    final map = <String, String>{};
    for (final book in curriculum.books) {
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          map[section.id] = section.label;
        }
      }
    }
    _sectionLabelById = map;
  }
}
