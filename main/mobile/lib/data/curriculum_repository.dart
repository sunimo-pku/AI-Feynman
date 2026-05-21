import 'dart:convert';

import 'package:flutter/services.dart';

import 'curriculum_models.dart';

class CurriculumRepository {
  CurriculumRepository._();

  static final CurriculumRepository instance = CurriculumRepository._();

  MathCurriculum? _cache;

  Future<MathCurriculum> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle
        .loadString('assets/curriculum/pep-junior-math.json');
    _cache = MathCurriculum.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    return _cache!;
  }
}
