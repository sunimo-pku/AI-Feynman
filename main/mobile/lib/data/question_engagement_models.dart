/// 题目收藏与家长反馈模型。
library;

class QuestionFavoriteItem {
  const QuestionFavoriteItem({
    required this.questionId,
    required this.sectionId,
    required this.questionPrompt,
    this.difficulty = 1,
    this.createdAt,
  });

  final String questionId;
  final String sectionId;
  final String questionPrompt;
  final int difficulty;
  final DateTime? createdAt;

  factory QuestionFavoriteItem.fromJson(Map<String, dynamic> json) {
    DateTime? at;
    final raw = json['createdAt'];
    if (raw is String && raw.isNotEmpty) {
      at = DateTime.tryParse(raw);
    }
    return QuestionFavoriteItem(
      questionId: json['questionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      createdAt: at,
    );
  }

  Map<String, dynamic> toJson() => {
        'questionId': questionId,
        'sectionId': sectionId,
        'questionPrompt': questionPrompt,
        'difficulty': difficulty,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };
}

class ParentQuestionFeedbackItem {
  const ParentQuestionFeedbackItem({
    required this.id,
    required this.questionId,
    required this.sectionId,
    required this.sectionLabel,
    required this.questionPrompt,
    required this.note,
    required this.studentName,
    this.difficulty = 1,
    this.createdAt,
  });

  final int id;
  final String questionId;
  final String sectionId;
  final String sectionLabel;
  final String questionPrompt;
  final String note;
  final String studentName;
  final int difficulty;
  final DateTime? createdAt;

  factory ParentQuestionFeedbackItem.fromJson(Map<String, dynamic> json) {
    DateTime? at;
    final raw = json['createdAt'];
    if (raw is String && raw.isNotEmpty) {
      at = DateTime.tryParse(raw);
    }
    return ParentQuestionFeedbackItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      questionId: json['questionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      note: json['note'] as String? ?? '',
      studentName: json['studentName'] as String? ?? '',
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      createdAt: at,
    );
  }
}
