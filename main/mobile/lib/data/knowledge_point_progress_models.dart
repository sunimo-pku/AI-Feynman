/// 知识点掌握度：0–5 星，用于同知识点内自适应出题难度。
library;

class KnowledgePointProgress {
  const KnowledgePointProgress({
    required this.knowledgePointId,
    required this.stars,
    required this.completedRounds,
    this.lastPracticedAt,
  });

  static const int maxStars = 5;

  final String knowledgePointId;

  /// 掌握星级 `[0, 5]`。不倒扣。
  final int stars;

  /// 该知识点累计完成讲解轮数（含未全员听懂的轮次）。
  final int completedRounds;

  final DateTime? lastPracticedAt;

  factory KnowledgePointProgress.empty(String knowledgePointId) {
    return KnowledgePointProgress(
      knowledgePointId: knowledgePointId,
      stars: 0,
      completedRounds: 0,
    );
  }

  KnowledgePointProgress copyWith({
    int? stars,
    int? completedRounds,
    DateTime? lastPracticedAt,
  }) {
    return KnowledgePointProgress(
      knowledgePointId: knowledgePointId,
      stars: stars ?? this.stars,
      completedRounds: completedRounds ?? this.completedRounds,
      lastPracticedAt: lastPracticedAt ?? this.lastPracticedAt,
    );
  }

  /// 每轮讲题结束后按同伴听懂情况更新星级。
  ///
  /// - 全员听懂 / completed：+1 星；`masteryDelta >= 1` 时 +2 星
  /// - 3 人里 ≥2 人听懂但未 completed：+1 星
  /// - 否则不变
  ({KnowledgePointProgress next, int starGain}) applyRound({
    required String status,
    required int masteryDelta,
    required int peersUnderstood,
    int totalPeers = 3,
    DateTime? when,
  }) {
    final safeTotal = totalPeers <= 0 ? 3 : totalPeers;
    var gain = 0;
    final allClear =
        status == 'completed' || peersUnderstood >= safeTotal;
    if (allClear) {
      gain = masteryDelta >= 1 ? 2 : 1;
    } else if (peersUnderstood >= 2) {
      gain = 1;
    }
    final capped = stars + gain;
    final nextStars = capped > maxStars ? maxStars : capped;
    return (
      next: copyWith(
        stars: nextStars,
        completedRounds: completedRounds + 1,
        lastPracticedAt: when ?? DateTime.now(),
      ),
      starGain: nextStars - stars,
    );
  }

  Map<String, dynamic> toJson() => {
        'knowledgePointId': knowledgePointId,
        'stars': stars,
        'completedRounds': completedRounds,
        'lastPracticedAt': lastPracticedAt?.toIso8601String(),
      };

  factory KnowledgePointProgress.fromJson(Map<String, dynamic> json) {
    final rawStars = (json['stars'] as num?)?.toInt() ?? 0;
    final stars = rawStars < 0
        ? 0
        : (rawStars > maxStars ? maxStars : rawStars);
    final rawRounds = (json['completedRounds'] as num?)?.toInt() ?? 0;
    final rounds = rawRounds < 0 ? 0 : rawRounds;
    DateTime? lastAt;
    final lastRaw = json['lastPracticedAt'];
    if (lastRaw is String && lastRaw.isNotEmpty) {
      lastAt = DateTime.tryParse(lastRaw);
    }
    return KnowledgePointProgress(
      knowledgePointId: json['knowledgePointId'] as String? ?? '',
      stars: stars,
      completedRounds: rounds,
      lastPracticedAt: lastAt,
    );
  }
}

/// 星级 → 推荐出题难度（1 基础 / 2 巩固 / 3 挑战）。
int difficultyForKnowledgePointStars(int stars) {
  if (stars <= 1) return 1;
  if (stars <= 3) return 2;
  return 3;
}

String knowledgePointStarLabel(int stars) {
  final clamped = stars < 0
      ? 0
      : (stars > KnowledgePointProgress.maxStars
          ? KnowledgePointProgress.maxStars
          : stars);
  if (clamped == 0) return '未练';
  return '$clamped 星';
}
