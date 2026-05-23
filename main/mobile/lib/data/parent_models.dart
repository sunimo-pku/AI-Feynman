/// 家长端 dashboard / poster 数据模型（第十轮）。
///
/// 与 `main/app/routers/parent.py` 的响应字段 1:1 对齐；任意字段加减都要
/// 前后端同步改。
library;

class WeakSectionInfo {
  const WeakSectionInfo({
    required this.sectionId,
    required this.label,
    required this.masteryScore,
    required this.completedRounds,
    required this.reason,
    this.lastPracticedAt,
    this.recentScores = const <int>[],
  });

  final String sectionId;
  final String label;
  final int masteryScore;
  final int completedRounds;
  final String reason;
  final DateTime? lastPracticedAt;
  final List<int> recentScores;

  factory WeakSectionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parseAt() {
      final raw = json['lastPracticedAt'];
      if (raw is String && raw.isNotEmpty) {
        return DateTime.tryParse(raw);
      }
      return null;
    }

    List<int> readScores() {
      final raw = json['recentScores'];
      if (raw is! List) return const <int>[];
      return raw
          .whereType<num>()
          .map((e) => e.toInt())
          .toList(growable: false);
    }

    return WeakSectionInfo(
      sectionId: json['sectionId'] as String? ?? '',
      label: json['label'] as String? ?? '',
      masteryScore: (json['masteryScore'] as num?)?.toInt() ?? 0,
      completedRounds: (json['completedRounds'] as num?)?.toInt() ?? 0,
      reason: json['reason'] as String? ?? '',
      lastPracticedAt: parseAt(),
      recentScores: readScores(),
    );
  }
}

class ParentReviewCard {
  const ParentReviewCard({
    required this.id,
    required this.sectionId,
    required this.sectionLabel,
    required this.questionId,
    required this.questionPrompt,
    required this.summary,
    required this.completedAt,
    required this.difficulty,
    required this.tags,
    required this.cautionPoints,
  });

  final String id;
  final String sectionId;
  final String sectionLabel;
  final String questionId;
  final String questionPrompt;
  final String summary;
  final DateTime completedAt;
  final int difficulty;
  final List<String> tags;
  final List<String> cautionPoints;

  factory ParentReviewCard.fromJson(Map<String, dynamic> json) {
    DateTime parseAt() {
      final raw = json['completedAt'];
      if (raw is String && raw.isNotEmpty) {
        return DateTime.tryParse(raw) ?? DateTime.now();
      }
      return DateTime.now();
    }

    List<String> readStringList(String key) {
      final raw = json[key];
      if (raw is! List) return const <String>[];
      return raw
          .where((e) => e != null)
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }

    return ParentReviewCard(
      id: json['id'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      completedAt: parseAt(),
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      tags: readStringList('tags'),
      cautionPoints: readStringList('cautionPoints'),
    );
  }
}

class DayActivity {
  const DayActivity({required this.date, required this.completedRounds});

  final String date;
  final int completedRounds;

  factory DayActivity.fromJson(Map<String, dynamic> json) {
    return DayActivity(
      date: json['date'] as String? ?? '',
      completedRounds: (json['completedRounds'] as num?)?.toInt() ?? 0,
    );
  }
}

class ParentDashboardPayload {
  const ParentDashboardPayload({
    required this.studentName,
    required this.grade,
    required this.overallMastery,
    required this.practicedSections,
    required this.completedRounds,
    required this.weakSections,
    required this.strongSections,
    required this.recentReviews,
    required this.weeklyActivity,
    required this.suggestedNextAction,
    required this.serverTime,
  });

  final String studentName;
  final String grade;
  final int overallMastery;
  final int practicedSections;
  final int completedRounds;
  final List<WeakSectionInfo> weakSections;
  final List<WeakSectionInfo> strongSections;
  final List<ParentReviewCard> recentReviews;
  final List<DayActivity> weeklyActivity;
  final String suggestedNextAction;
  final DateTime serverTime;

  factory ParentDashboardPayload.fromJson(Map<String, dynamic> json) {
    List<WeakSectionInfo> readSections(String key) {
      final raw = json[key];
      if (raw is! List) return const <WeakSectionInfo>[];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(WeakSectionInfo.fromJson)
          .toList(growable: false);
    }

    final reviews = json['recentReviews'];
    final reviewCards = reviews is List
        ? reviews
            .whereType<Map<String, dynamic>>()
            .map(ParentReviewCard.fromJson)
            .toList(growable: false)
        : const <ParentReviewCard>[];

    final activityRaw = json['weeklyActivity'];
    final weeklyActivity = activityRaw is List
        ? activityRaw
            .whereType<Map<String, dynamic>>()
            .map(DayActivity.fromJson)
            .toList(growable: false)
        : const <DayActivity>[];

    return ParentDashboardPayload(
      studentName: json['studentName'] as String? ?? '同学',
      grade: json['grade'] as String? ?? '八年级',
      overallMastery: (json['overallMastery'] as num?)?.toInt() ?? 0,
      practicedSections: (json['practicedSections'] as num?)?.toInt() ?? 0,
      completedRounds: (json['completedRounds'] as num?)?.toInt() ?? 0,
      weakSections: readSections('weakSections'),
      strongSections: readSections('strongSections'),
      recentReviews: reviewCards,
      weeklyActivity: weeklyActivity,
      suggestedNextAction: json['suggestedNextAction'] as String? ?? '',
      serverTime: DateTime.tryParse(
              (json['serverTime'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}

class ParentPosterPayload {
  const ParentPosterPayload({
    required this.studentName,
    required this.grade,
    required this.weekCompletedRounds,
    required this.highestSection,
    required this.highestScore,
    required this.weakestSection,
    required this.weakestScore,
    required this.teacherTip,
    required this.lastQuestionPrompt,
    required this.lastSummary,
    required this.generatedAt,
  });

  final String studentName;
  final String grade;
  final int weekCompletedRounds;
  final String highestSection;
  final int highestScore;
  final String weakestSection;
  final int weakestScore;
  final String teacherTip;
  final String lastQuestionPrompt;
  final String lastSummary;
  final DateTime generatedAt;

  factory ParentPosterPayload.fromJson(Map<String, dynamic> json) {
    return ParentPosterPayload(
      studentName: json['studentName'] as String? ?? '同学',
      grade: json['grade'] as String? ?? '八年级',
      weekCompletedRounds: (json['weekCompletedRounds'] as num?)?.toInt() ?? 0,
      highestSection: json['highestSection'] as String? ?? '',
      highestScore: (json['highestScore'] as num?)?.toInt() ?? 0,
      weakestSection: json['weakestSection'] as String? ?? '',
      weakestScore: (json['weakestScore'] as num?)?.toInt() ?? 0,
      teacherTip: json['teacherTip'] as String? ?? '',
      lastQuestionPrompt: json['lastQuestionPrompt'] as String? ?? '',
      lastSummary: json['lastSummary'] as String? ?? '',
      generatedAt: DateTime.tryParse(
              (json['generatedAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}
