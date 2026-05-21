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
    required this.sectionId,
    required this.prompt,
    required this.wrongStep,
    required this.errorBox,
    required this.rewardCrystals,
    required this.rewardPower,
  });

  final String challengeId;
  final String sectionId;
  final String prompt;
  final String wrongStep;
  final Map<String, num> errorBox;
  final int rewardCrystals;
  final int rewardPower;

  factory BountyChallenge.fromJson(Map<String, dynamic> json) {
    final rawBox = json['errorBox'];
    return BountyChallenge(
      challengeId: json['challengeId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      wrongStep: json['wrongStep'] as String? ?? '',
      errorBox: rawBox is Map
          ? rawBox.map((k, v) => MapEntry(k.toString(), (v as num?) ?? 0))
          : const <String, num>{},
      rewardCrystals: (json['rewardCrystals'] as num?)?.toInt() ?? 0,
      rewardPower: (json['rewardPower'] as num?)?.toInt() ?? 0,
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
