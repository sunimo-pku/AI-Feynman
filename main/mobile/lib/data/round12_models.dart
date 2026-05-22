library;

class PowerProfile {
  const PowerProfile({
    required this.studentName,
    required this.equippedTitle,
    required this.crystalBalance,
    required this.sections,
  });

  final String studentName;
  final String equippedTitle;
  final int crystalBalance;
  final List<PowerSection> sections;

  factory PowerProfile.fromJson(Map<String, dynamic> json) {
    final raw = json['sections'];
    return PowerProfile(
      studentName: json['studentName'] as String? ?? '同学',
      equippedTitle: json['equippedTitle'] as String? ?? '',
      crystalBalance: (json['crystalBalance'] as num?)?.toInt() ?? 0,
      sections: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(PowerSection.fromJson)
              .toList(growable: false)
          : const <PowerSection>[],
    );
  }
}

class PowerSection {
  const PowerSection({
    required this.sectionId,
    required this.powerScore,
    required this.rankTier,
  });

  final String sectionId;
  final int powerScore;
  final String rankTier;

  factory PowerSection.fromJson(Map<String, dynamic> json) {
    return PowerSection(
      sectionId: json['sectionId'] as String? ?? '',
      powerScore: (json['powerScore'] as num?)?.toInt() ?? 0,
      rankTier: json['rankTier'] as String? ?? '青铜',
    );
  }
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.studentId,
    required this.studentName,
    required this.powerScore,
    required this.rankTier,
    required this.titleLabel,
  });

  final int rank;
  final int studentId;
  final String studentName;
  final int powerScore;
  final String rankTier;
  final String titleLabel;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      studentId: (json['studentId'] as num?)?.toInt() ?? 0,
      studentName: json['studentName'] as String? ?? '同学',
      powerScore: (json['powerScore'] as num?)?.toInt() ?? 0,
      rankTier: json['rankTier'] as String? ?? '青铜',
      titleLabel: json['titleLabel'] as String? ?? '',
    );
  }
}

class BountyChallenge {
  const BountyChallenge({
    required this.challengeId,
    required this.track,
    required this.sectionId,
    required this.questionId,
    required this.sectionLabel,
    required this.prompt,
    required this.wrongStep,
    required this.wrongSolution,
    required this.errorBox,
    required this.tags,
    required this.difficulty,
    required this.rewardCrystals,
    required this.rewardPower,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.status,
    required this.attemptCount,
    required this.circledCorrectly,
    required this.explanationScore,
    required this.feedback,
    required this.rewardGranted,
  });

  final String challengeId;
  final String track;
  final String sectionId;
  final String questionId;
  final String sectionLabel;
  final String prompt;
  final String wrongStep;
  final List<String> wrongSolution;
  final Map<String, num> errorBox;
  final List<String> tags;
  final int difficulty;
  final int rewardCrystals;
  final int rewardPower;
  final int canvasWidth;
  final int canvasHeight;
  final String status;
  final int attemptCount;
  final bool circledCorrectly;
  final int explanationScore;
  final BountyFeedback feedback;
  final bool rewardGranted;

  bool get isCompleted => status == 'completed';

  factory BountyChallenge.fromJson(Map<String, dynamic> json) {
    final rawBox = json['errorBox'];
    final rawSolution = json['wrongSolution'];
    final rawTags = json['tags'];
    return BountyChallenge(
      challengeId: json['challengeId'] as String? ?? '',
      track: json['track'] as String? ?? 'review',
      sectionId: json['sectionId'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      wrongStep: json['wrongStep'] as String? ?? '',
      wrongSolution: rawSolution is List
          ? rawSolution.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      errorBox: rawBox is Map
          ? rawBox.map((k, v) => MapEntry(k.toString(), (v as num?) ?? 0))
          : const <String, num>{},
      tags: rawTags is List
          ? rawTags.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      rewardCrystals: (json['rewardCrystals'] as num?)?.toInt() ?? 0,
      rewardPower: (json['rewardPower'] as num?)?.toInt() ?? 0,
      canvasWidth: (json['canvasWidth'] as num?)?.toInt() ?? 640,
      canvasHeight: (json['canvasHeight'] as num?)?.toInt() ?? 360,
      status: json['status'] as String? ?? 'notStarted',
      attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
      circledCorrectly: json['circledCorrectly'] == true,
      explanationScore: (json['explanationScore'] as num?)?.toInt() ?? 0,
      feedback: BountyFeedback.fromJson(
        json['feedback'] is Map<String, dynamic>
            ? json['feedback'] as Map<String, dynamic>
            : const <String, dynamic>{},
      ),
      rewardGranted: json['rewardGranted'] == true,
    );
  }
}

class BountyToday {
  const BountyToday({
    required this.dateKey,
    required this.completedCount,
    required this.totalCount,
    required this.totalCrystals,
    required this.challenges,
  });

  final String dateKey;
  final int completedCount;
  final int totalCount;
  final int totalCrystals;
  final List<BountyChallenge> challenges;

  factory BountyToday.fromJson(Map<String, dynamic> json) {
    final raw = json['challenges'];
    final challenges = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(BountyChallenge.fromJson)
            .toList(growable: false)
        : const <BountyChallenge>[];
    return BountyToday(
      dateKey: (json['dateKey'] as String?) ?? (json['date'] as String?) ?? '',
      completedCount: (json['completedCount'] as num?)?.toInt() ??
          challenges.where((c) => c.isCompleted).length,
      totalCount: (json['totalCount'] as num?)?.toInt() ?? challenges.length,
      totalCrystals: (json['totalCrystals'] as num?)?.toInt() ??
          challenges.fold<int>(0, (sum, c) => sum + c.rewardCrystals),
      challenges: challenges,
    );
  }
}

class BountyFeedback {
  const BountyFeedback({
    required this.summary,
    required this.nextHint,
    required this.iouScore,
    required this.explanationScore,
    required this.keywordHits,
  });

  final String summary;
  final String nextHint;
  final double iouScore;
  final int explanationScore;
  final List<String> keywordHits;

  factory BountyFeedback.fromJson(Map<String, dynamic> json) {
    final rawHits = json['keywordHits'];
    return BountyFeedback(
      summary: json['summary'] as String? ?? '',
      nextHint: json['nextHint'] as String? ?? '',
      iouScore: (json['iouScore'] as num?)?.toDouble() ?? 0,
      explanationScore: (json['explanationScore'] as num?)?.toInt() ?? 0,
      keywordHits: rawHits is List
          ? rawHits.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
    );
  }
}

class BountySubmitResult {
  const BountySubmitResult({
    required this.completed,
    required this.status,
    required this.circledCorrectly,
    required this.iouScore,
    required this.explanationScore,
    required this.crystalReward,
    required this.powerReward,
    required this.rewardGranted,
    required this.feedback,
    required this.attemptCount,
  });

  final bool completed;
  final String status;
  final bool circledCorrectly;
  final double iouScore;
  final int explanationScore;
  final int crystalReward;
  final int powerReward;
  final bool rewardGranted;
  final BountyFeedback feedback;
  final int attemptCount;

  factory BountySubmitResult.fromJson(Map<String, dynamic> json) {
    return BountySubmitResult(
      completed: json['completed'] == true,
      status: json['status'] as String? ?? 'inProgress',
      circledCorrectly: json['circledCorrectly'] == true,
      iouScore: (json['iouScore'] as num?)?.toDouble() ?? 0,
      explanationScore: (json['explanationScore'] as num?)?.toInt() ?? 0,
      crystalReward: (json['crystalReward'] as num?)?.toInt() ?? 0,
      powerReward: (json['powerReward'] as num?)?.toInt() ?? 0,
      rewardGranted: json['rewardGranted'] == true,
      feedback: BountyFeedback.fromJson(
        json['feedback'] is Map<String, dynamic>
            ? json['feedback'] as Map<String, dynamic>
            : const <String, dynamic>{},
      ),
      attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class ShopCatalog {
  const ShopCatalog({
    required this.balance,
    required this.items,
    required this.geekSkus,
  });

  final int balance;
  final List<ShopItem> items;
  final List<ShopItem> geekSkus;

  factory ShopCatalog.fromJson(Map<String, dynamic> json) {
    List<ShopItem> read(String key) {
      final raw = json[key];
      return raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(ShopItem.fromJson)
              .toList(growable: false)
          : const <ShopItem>[];
    }

    return ShopCatalog(
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      items: read('items'),
      geekSkus: read('geekSkus'),
    );
  }
}

class ShopItem {
  const ShopItem({
    required this.skuId,
    required this.name,
    required this.type,
    required this.crystalCost,
  });

  final String skuId;
  final String name;
  final String type;
  final int crystalCost;

  factory ShopItem.fromJson(Map<String, dynamic> json) {
    return ShopItem(
      skuId: json['skuId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? '',
      crystalCost: (json['crystalCost'] as num?)?.toInt() ?? 0,
    );
  }
}

class ReplaySummary {
  const ReplaySummary({
    required this.sessionId,
    required this.sectionId,
    required this.questionId,
    required this.questionPrompt,
    required this.durationMs,
    required this.createdAt,
  });

  final String sessionId;
  final String sectionId;
  final String questionId;
  final String questionPrompt;
  final int durationMs;
  final DateTime createdAt;

  factory ReplaySummary.fromJson(Map<String, dynamic> json) {
    return ReplaySummary(
      sessionId: json['sessionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      questionId: json['questionId'] as String? ?? '',
      questionPrompt: json['questionPrompt'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class ParentChild {
  const ParentChild({
    required this.studentId,
    required this.nickname,
    required this.active,
  });

  final int studentId;
  final String nickname;
  final bool active;

  factory ParentChild.fromJson(Map<String, dynamic> json) {
    return ParentChild(
      studentId: (json['studentId'] as num?)?.toInt() ?? 0,
      nickname: json['nickname'] as String? ?? '同学',
      active: json['active'] == true,
    );
  }
}
