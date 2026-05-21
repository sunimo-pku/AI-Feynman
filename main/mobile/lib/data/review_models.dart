/// 第八轮：本地讲题回顾记录数据模型。
///
/// 每次学生在讲题页拿到后端返回的 `status: "completed"` 时，前端会拼装一条
/// [LectureReviewRecord] 写入 `shared_preferences`，供回顾页倒序展示。
///
/// 设计约束（来自 `docs/AI_CODE_AGENT_BRIEF_ROUND8.md`）：
///   * 本轮**不**再次调用 LLM；`summary` 沿用第六轮拼装结果，`agentHighlights`
///     从最后几条 AI turn 抠出短文本，`cautionPoints` 用本地规则按题目标签
///     生成 —— 全部纯 Dart 算出来，不引入新接口。
///   * 字段语义稳定后破坏格式需要同步升 storage key（例如 `.v2`），以避免
///     老用户升级后读出的字段语义漂移。
///   * 不保存手写笔迹点集、不保存完整聊天记录，只留下学生「回看一眼」需要的
///     最小信息集合 —— V1 边界明确禁止做"完整聊天检索"。
library;

class LectureReviewRecord {
  const LectureReviewRecord({
    required this.id,
    required this.sectionId,
    required this.questionId,
    required this.questionPrompt,
    required this.difficulty,
    required this.tags,
    required this.completedAt,
    required this.summary,
    required this.agentHighlights,
    required this.cautionPoints,
  });

  /// 本地唯一 ID。建议格式：`'$questionId-${millis}'`，便于人眼对账。
  final String id;
  final String sectionId;
  final String questionId;

  /// 题面 LaTeX 源文本，渲染时交给 `FormulaText`。
  final String questionPrompt;

  /// 难度（1/2/3），UI 展示统一经 `MockLectureRepository.difficultyLabel`
  /// 翻译成「基础/巩固/挑战」，**不**直接渲染数字。
  final int difficulty;
  final List<String> tags;

  /// 完成时间（本地时区）。`shared_preferences` 里以 ISO-8601 字符串保存，
  /// 旧记录解析失败时退回 `DateTime.now()`，避免回顾卡片崩成空。
  final DateTime completedAt;

  /// 本题总结（沿用第六轮 `lastSummary` 的拼装结果：teacher → AI → 兜底）。
  final String summary;

  /// AI 追问摘要：从本题最后几条 AI turn 中抽出的 1-3 条短文本。
  /// 用于回顾卡片二段「AI 同伴聊了什么」部分。
  final List<String> agentHighlights;

  /// 待注意点：本地规则按题目标签生成，最多 3 条。
  /// 见 `ReviewRepository.derivCautionPoints` 的硬规则集合。
  final List<String> cautionPoints;

  LectureReviewRecord copyWith({
    String? id,
    String? sectionId,
    String? questionId,
    String? questionPrompt,
    int? difficulty,
    List<String>? tags,
    DateTime? completedAt,
    String? summary,
    List<String>? agentHighlights,
    List<String>? cautionPoints,
  }) {
    return LectureReviewRecord(
      id: id ?? this.id,
      sectionId: sectionId ?? this.sectionId,
      questionId: questionId ?? this.questionId,
      questionPrompt: questionPrompt ?? this.questionPrompt,
      difficulty: difficulty ?? this.difficulty,
      tags: tags ?? this.tags,
      completedAt: completedAt ?? this.completedAt,
      summary: summary ?? this.summary,
      agentHighlights: agentHighlights ?? this.agentHighlights,
      cautionPoints: cautionPoints ?? this.cautionPoints,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sectionId': sectionId,
        'questionId': questionId,
        'questionPrompt': questionPrompt,
        'difficulty': difficulty,
        'tags': tags,
        'completedAt': completedAt.toIso8601String(),
        'summary': summary,
        'agentHighlights': agentHighlights,
        'cautionPoints': cautionPoints,
      };

  /// 容错解析：任意字段缺失 / 类型不符都回落到默认值，不抛异常。
  /// 老用户本地 JSON 哪怕半残也能继续渲染 —— 与 `SectionProgress.fromJson`
  /// 一致的口径，避免「升级后所有回顾消失」的体感。
  factory LectureReviewRecord.fromJson(Map<String, dynamic> json) {
    DateTime parseCompletedAt() {
      final raw = json['completedAt'];
      if (raw is String && raw.isNotEmpty) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) return parsed;
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

    final rawDifficulty = (json['difficulty'] as num?)?.toInt() ?? 1;
    final difficulty = rawDifficulty < 1
        ? 1
        : (rawDifficulty > 3 ? 3 : rawDifficulty);

    return LectureReviewRecord(
      id: json['id'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      difficulty: difficulty,
      tags: readStringList('tags'),
      completedAt: parseCompletedAt(),
      summary: json['summary'] as String? ?? '',
      agentHighlights: readStringList('agentHighlights'),
      cautionPoints: readStringList('cautionPoints'),
    );
  }
}
