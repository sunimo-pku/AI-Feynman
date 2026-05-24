/// 第六轮：本地学习进度数据模型。
///
/// 仅用于「按 `sectionId` 记录学生在该小节的本地掌握度 / 完成次数 /
/// 最近一条小结文案」，本轮不接后端 DB，不做账号级跨设备同步。
///
/// 设计约束（来自 `docs/AI_CODE_AGENT_BRIEF_ROUND6.md`）：
///   * 数据只覆盖 V1 可练习的 16.1 / 16.2 / 16.3 三节，但模型本身不锁
///     `sectionId` 白名单 —— 后续上线新小节时新增即可，仓库层负责按
///     `CurriculumSection.isAvailable` 过滤展示。
///   * `masteryScore` 限 `[0, 100]`，无倒扣，无遗忘曲线。
///   * `lastSummary` 是「上一次完成时的本题小结」，文案在前端拼装（取最后
///     一条 teacher / AI turn），**不**为了总结再调一次 LLM。
///   * `toJson` / `fromJson` 与 `ai_feynman.section_progress.v1` 存储 key
///     一一对应，破坏字段格式需要同步升 key（例如改成 `.v2`）以避免老用户
///     升级后读出 garbage。
library;

class SectionProgress {
  const SectionProgress({
    required this.sectionId,
    required this.completedRounds,
    required this.masteryScore,
    this.lastPracticedAt,
    this.lastSummary = '',
  });

  final String sectionId;

  /// 本节累计「老师说 completed」的次数。每次 `/lecture/submit` 返回
  /// `status: "completed"` 时 +1，不区分是不是同一道题。
  final int completedRounds;

  /// 本节当前掌握度，范围 `[0, 100]`。第六轮算法：
  ///   * 初始 0；
  ///   * 每次 positive completed：`+= max(8, masteryDelta * 10)`，上限 100；
  ///   * 不倒扣，不衰减。
  final int masteryScore;

  /// 上一次完成时的本地时间（用于 UI 「最近练习于 …」二级文字）。
  final DateTime? lastPracticedAt;

  /// 上一次完成时的「本题讲题小结」文案。优先取后端最后一条 teacher turn，
  /// 没有就取最后一条 AI turn；都没有时用兜底文案。可能含 LaTeX 片段，
  /// 渲染时交给 `FormulaText` 处理。
  final String lastSummary;

  /// 「空进度」工厂：用于首页第一次进入某小节时的默认展示。
  factory SectionProgress.empty(String sectionId) {
    return SectionProgress(
      sectionId: sectionId,
      completedRounds: 0,
      masteryScore: 0,
    );
  }

  bool get hasAnyCompletion => completedRounds > 0;

  SectionProgress copyWith({
    int? completedRounds,
    int? masteryScore,
    DateTime? lastPracticedAt,
    String? lastSummary,
  }) {
    return SectionProgress(
      sectionId: sectionId,
      completedRounds: completedRounds ?? this.completedRounds,
      masteryScore: masteryScore ?? this.masteryScore,
      lastPracticedAt: lastPracticedAt ?? this.lastPracticedAt,
      lastSummary: lastSummary ?? this.lastSummary,
    );
  }

  /// 应用一次 `/lecture/submit` 返回的 completed 结果。
  ///
  /// 按 brief 第 5 节：
  ///   * `masteryDelta <= 0` 时不计入本地进度；
  ///   * positive delta 时 `completedRounds += 1`
  ///   * `masteryScore += max(8, masteryDelta * 10)`，上限 100
  ///
  /// 返回 `(next, gained)`：`gained` 是本次真正加的分数（已考虑 100 上限），
  /// UI 可以拿来显示「本节掌握度 +X」。
  ({SectionProgress next, int gained}) applyCompleted({
    required int masteryDelta,
    required String summary,
    required DateTime when,
  }) {
    if (masteryDelta <= 0) {
      return (next: this, gained: 0);
    }
    final rawGain = masteryDelta * 10;
    final gainCandidate = rawGain >= 8 ? rawGain : 8;
    final nextScoreRaw = masteryScore + gainCandidate;
    final nextScore = nextScoreRaw > 100 ? 100 : nextScoreRaw;
    final actualGain = nextScore - masteryScore;
    final cleanSummary = summary.trim();
    return (
      next: copyWith(
        completedRounds: completedRounds + 1,
        masteryScore: nextScore,
        lastPracticedAt: when,
        lastSummary: cleanSummary.isEmpty ? lastSummary : cleanSummary,
      ),
      gained: actualGain,
    );
  }

  Map<String, dynamic> toJson() => {
    'sectionId': sectionId,
    'completedRounds': completedRounds,
    'masteryScore': masteryScore,
    'lastPracticedAt': lastPracticedAt?.toIso8601String(),
    'lastSummary': lastSummary,
  };

  /// 容错解析：任意字段缺失 / 类型不符都回落到默认值，不抛异常。
  /// 老用户本地 JSON 哪怕半残也能继续用，避免「升级后所有进度清零」的体感。
  factory SectionProgress.fromJson(Map<String, dynamic> json) {
    final rawScore = (json['masteryScore'] as num?)?.toInt() ?? 0;
    final clampedScore = rawScore < 0 ? 0 : (rawScore > 100 ? 100 : rawScore);
    final rawRounds = (json['completedRounds'] as num?)?.toInt() ?? 0;
    final rounds = rawRounds < 0 ? 0 : rawRounds;
    DateTime? lastAt;
    final lastRaw = json['lastPracticedAt'];
    if (lastRaw is String && lastRaw.isNotEmpty) {
      lastAt = DateTime.tryParse(lastRaw);
    }
    return SectionProgress(
      sectionId: json['sectionId'] as String? ?? '',
      completedRounds: rounds,
      masteryScore: clampedScore,
      lastPracticedAt: lastAt,
      lastSummary: json['lastSummary'] as String? ?? '',
    );
  }
}
