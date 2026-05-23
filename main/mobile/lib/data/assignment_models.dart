/// 家长布置作业 / 学生待办数据模型。
library;

class AssignmentItem {
  const AssignmentItem({
    required this.assignmentId,
    required this.title,
    required this.note,
    required this.sourceType,
    required this.sectionId,
    required this.sectionLabel,
    required this.questionId,
    required this.questionPrompt,
    required this.difficulty,
    required this.dueAt,
    required this.status,
    required this.createdAt,
    this.openedAt,
    this.completedAt,
    this.completionSummary = '',
  });

  final String assignmentId;
  final String title;
  final String note;
  final String sourceType;
  final String sectionId;
  final String sectionLabel;
  final String questionId;
  final String questionPrompt;
  final int difficulty;
  final DateTime dueAt;
  final String status;
  final DateTime createdAt;
  final DateTime? openedAt;
  final DateTime? completedAt;
  final String completionSummary;

  bool get isActive => status != 'completed';

  factory AssignmentItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseOpt(String key) {
      final raw = json[key];
      if (raw is String && raw.isNotEmpty) {
        return DateTime.tryParse(raw);
      }
      return null;
    }

    DateTime parseReq(String key) => parseOpt(key) ?? DateTime.now();

    return AssignmentItem(
      assignmentId: json['assignmentId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      sourceType: json['sourceType'] as String? ?? 'catalog',
      sectionId: json['sectionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      dueAt: parseReq('dueAt'),
      status: json['status'] as String? ?? 'pending',
      createdAt: parseReq('createdAt'),
      openedAt: parseOpt('openedAt'),
      completedAt: parseOpt('completedAt'),
      completionSummary: json['completionSummary'] as String? ?? '',
    );
  }
}

class AssignmentReport {
  const AssignmentReport({
    required this.assignmentId,
    required this.title,
    required this.note,
    required this.sectionLabel,
    required this.questionPrompt,
    required this.status,
    required this.dueAt,
    required this.completedAt,
    required this.onTime,
    required this.summary,
    required this.agentHighlights,
    required this.cautionPoints,
    required this.masteryDelta,
    required this.roundCount,
    required this.transcriptText,
    required this.turns,
  });

  final String assignmentId;
  final String title;
  final String note;
  final String sectionLabel;
  final String questionPrompt;
  final String status;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final bool onTime;
  final String summary;
  final List<String> agentHighlights;
  final List<String> cautionPoints;
  final int masteryDelta;
  final int roundCount;
  final String transcriptText;
  final List<Map<String, dynamic>> turns;

  factory AssignmentReport.fromJson(Map<String, dynamic> json) {
    DateTime? parseOpt(String key) {
      final raw = json[key];
      if (raw is String && raw.isNotEmpty) {
        return DateTime.tryParse(raw);
      }
      return null;
    }

    List<String> readStrings(String key) {
      final raw = json[key];
      if (raw is! List) return const <String>[];
      return raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList(growable: false);
    }

    final turnsRaw = json['turns'];
    final turns = turnsRaw is List
        ? turnsRaw.whereType<Map<String, dynamic>>().toList(growable: false)
        : const <Map<String, dynamic>>[];

    return AssignmentReport(
      assignmentId: json['assignmentId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      status: json['status'] as String? ?? '',
      dueAt: parseOpt('dueAt'),
      completedAt: parseOpt('completedAt'),
      onTime: json['onTime'] as bool? ?? true,
      summary: json['summary'] as String? ?? '',
      agentHighlights: readStrings('agentHighlights'),
      cautionPoints: readStrings('cautionPoints'),
      masteryDelta: (json['masteryDelta'] as num?)?.toInt() ?? 0,
      roundCount: (json['roundCount'] as num?)?.toInt() ?? 0,
      transcriptText: json['transcriptText'] as String? ?? '',
      turns: turns,
    );
  }
}

class AssignmentRecommendation {
  const AssignmentRecommendation({
    required this.reason,
    required this.reasonType,
    required this.sectionId,
    required this.sectionLabel,
    required this.questionId,
    required this.questionPrompt,
    required this.difficulty,
    required this.difficultyLabel,
    this.knowledgePointId = '',
    this.knowledgePointLabel = '',
    this.masteryScore,
  });

  final String reason;
  final String reasonType;
  final String sectionId;
  final String sectionLabel;
  final String questionId;
  final String questionPrompt;
  final int difficulty;
  final String difficultyLabel;
  final String knowledgePointId;
  final String knowledgePointLabel;
  final int? masteryScore;

  factory AssignmentRecommendation.fromJson(Map<String, dynamic> json) {
    return AssignmentRecommendation(
      reason: json['reason'] as String? ?? '',
      reasonType: json['reasonType'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      difficultyLabel: json['difficultyLabel'] as String? ?? '基础',
      knowledgePointId: json['knowledgePointId'] as String? ?? '',
      knowledgePointLabel: json['knowledgePointLabel'] as String? ?? '',
      masteryScore: (json['masteryScore'] as num?)?.toInt(),
    );
  }
}

class RecognizedQuestion {
  const RecognizedQuestion({
    required this.sectionId,
    required this.questionPrompt,
    required this.knowledgeTags,
    required this.confidence,
  });

  final String sectionId;
  final String questionPrompt;
  final List<String> knowledgeTags;
  final double confidence;

  factory RecognizedQuestion.fromJson(Map<String, dynamic> json) {
    final tagsRaw = json['knowledgeTags'];
    return RecognizedQuestion(
      sectionId: json['sectionId'] as String? ?? 'unknown',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      knowledgeTags: tagsRaw is List
          ? tagsRaw.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    );
  }
}
