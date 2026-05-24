/// 可解释长期学习画像。
///
/// 与后端 `/learning/profile-insights` 和 `/parent/profile-insights`
/// 响应字段保持一致。
library;

class ProfileEvidence {
  const ProfileEvidence({required this.label, required this.detail});

  final String label;
  final String detail;

  factory ProfileEvidence.fromJson(Map<String, dynamic> json) {
    return ProfileEvidence(
      label: json['label'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
    );
  }
}

class ProfileInsight {
  const ProfileInsight({
    required this.title,
    required this.description,
    required this.evidence,
  });

  final String title;
  final String description;
  final List<ProfileEvidence> evidence;

  factory ProfileInsight.fromJson(Map<String, dynamic> json) {
    final raw = json['evidence'];
    final evidence =
        raw is List
            ? raw
                .whereType<Map<String, dynamic>>()
                .map(ProfileEvidence.fromJson)
                .toList(growable: false)
            : const <ProfileEvidence>[];
    return ProfileInsight(
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      evidence: evidence,
    );
  }
}

class LearningProfilePayload {
  const LearningProfilePayload({
    required this.studentName,
    required this.grade,
    required this.overview,
    required this.aiSummary,
    required this.profileSource,
    required this.dataPoints,
    required this.weakKnowledge,
    required this.strengths,
    required this.learningTraits,
    required this.nextActions,
    required this.generatedAt,
  });

  final String studentName;
  final String grade;
  final String overview;
  final String aiSummary;
  final String profileSource;
  final int dataPoints;
  final List<ProfileInsight> weakKnowledge;
  final List<ProfileInsight> strengths;
  final List<ProfileInsight> learningTraits;
  final List<String> nextActions;
  final DateTime generatedAt;

  factory LearningProfilePayload.fromJson(Map<String, dynamic> json) {
    List<ProfileInsight> readInsights(String key) {
      final raw = json[key];
      if (raw is! List) return const <ProfileInsight>[];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(ProfileInsight.fromJson)
          .toList(growable: false);
    }

    List<String> readStrings(String key) {
      final raw = json[key];
      if (raw is! List) return const <String>[];
      return raw
          .where((item) => item != null)
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return LearningProfilePayload(
      studentName: json['studentName'] as String? ?? '同学',
      grade: json['grade'] as String? ?? '',
      overview: json['overview'] as String? ?? '',
      aiSummary: json['aiSummary'] as String? ?? '',
      profileSource: json['profileSource'] as String? ?? 'rules',
      dataPoints: (json['dataPoints'] as num?)?.toInt() ?? 0,
      weakKnowledge: readInsights('weakKnowledge'),
      strengths: readInsights('strengths'),
      learningTraits: readInsights('learningTraits'),
      nextActions: readStrings('nextActions'),
      generatedAt:
          DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
