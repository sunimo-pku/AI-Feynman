/// 讲题 / 多 Agent 对话相关的纯数据模型。
///
/// 第二轮起，多 Agent 回复 (`turns`) 由后端 `POST /lecture/submit` 返回；
/// 本地仍保留题目 Mock (`LectureQuestion`)，避免后端尚未启动时整张讲题页空白。
library;

enum AgentRole {
  xiaoming,
  daxiong,
  classLeader,
  monitor,
  teacher,
  system,
}

AgentRole parseAgentRole(String raw) {
  switch (raw) {
    case 'xiaoming':
      return AgentRole.xiaoming;
    case 'daxiong':
      return AgentRole.daxiong;
    case 'classLeader':
    case 'class_leader':
      return AgentRole.classLeader;
    // 后端约定的「班长」枚举名是 monitor，前端兼容两种写法。
    case 'monitor':
      return AgentRole.monitor;
    case 'teacher':
      return AgentRole.teacher;
    default:
      return AgentRole.system;
  }
}

/// 把前端 [AgentRole] 翻译成后端约定的 wire role 字符串。
///
/// 第五轮 `LectureHistoryItem.role` 必须用后端能识别的字符串
/// （`xiaoming/daxiong/monitor/teacher/system`，前端的 `classLeader`
/// 也被映射到 `monitor`）。`student` 角色在前端没有枚举，由调用方
/// 直接写字符串字面量 `'student'`。
String agentRoleWire(AgentRole role) {
  switch (role) {
    case AgentRole.xiaoming:
      return 'xiaoming';
    case AgentRole.daxiong:
      return 'daxiong';
    case AgentRole.classLeader:
    case AgentRole.monitor:
      return 'monitor';
    case AgentRole.teacher:
      return 'teacher';
    case AgentRole.system:
      return 'system';
  }
}

class AgentTurn {
  const AgentTurn({
    this.turnId,
    required this.role,
    required this.displayName,
    required this.text,
    this.highlightStepIds = const [],
  });

  final String? turnId;
  final AgentRole role;
  final String displayName;
  final String text;
  final List<String> highlightStepIds;

  factory AgentTurn.fromJson(Map<String, dynamic> json) {
    return AgentTurn(
      turnId: json['turnId'] as String?,
      role: parseAgentRole(json['role'] as String? ?? 'system'),
      displayName: json['displayName'] as String? ?? '匿名',
      text: json['text'] as String? ?? '',
      highlightStepIds: (json['highlightStepIds'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
    );
  }
}

class LectureQuestion {
  const LectureQuestion({
    required this.questionId,
    required this.sectionId,
    required this.sectionLabel,
    required this.prompt,
    required this.hint,
    required this.referenceSteps,
    this.difficulty = 1,
    this.tags = const <String>[],
    this.image,
  });

  final String questionId;
  final String sectionId;
  final String sectionLabel;

  /// LaTeX 源文本，渲染时由 `FormulaText` 处理。
  final String prompt;

  /// 题面下方的一句话提示。
  final String hint;

  /// 老师内部记录的参考步骤（V1 仅用于 Mock 追问，前端不直接展示）。
  final List<String> referenceSteps;

  /// 第七轮新增：题目难度（1=基础 / 2=巩固 / 3=挑战）。
  ///
  /// 仅作为开发字段，UI 中必须经 [MockLectureRepository.difficultyLabel]
  /// 翻译成中文展示，禁止在页面里暴露 `1/2/3` 这种数值。
  final int difficulty;

  /// 第七轮新增：题目知识标签（如 `["取值范围", "非负条件"]`）。
  ///
  /// 仅前端展示用，**不**会作为后端 `/lecture/submit` 的请求字段。
  /// 单题建议 1-3 个，避免题面卡片拥挤。
  final List<String> tags;

  /// 可选题图。JSON 中只保存 asset 路径与无障碍描述，图片文件单独放 assets。
  final QuestionImage? image;

  factory LectureQuestion.fromJson(Map<String, dynamic> json) {
    List<String> readStringList(String key) {
      final raw = json[key];
      if (raw is! List) return const <String>[];
      return raw
          .where((e) => e != null)
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }

    return LectureQuestion(
      questionId: json['questionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      sectionLabel: json['sectionLabel'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      hint: json['hint'] as String? ?? '',
      referenceSteps: readStringList('referenceSteps'),
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
      tags: readStringList('tags'),
      image: QuestionImage.fromJson(json['image']),
    );
  }
}

class QuestionImage {
  const QuestionImage({
    required this.asset,
    required this.alt,
  });

  final String asset;
  final String alt;

  static QuestionImage? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final asset = raw['asset'] as String? ?? '';
    if (asset.isEmpty) return null;
    return QuestionImage(
      asset: asset,
      alt: raw['alt'] as String? ?? '题目配图',
    );
  }
}

/// 单条多轮上下文历史项。
///
/// 第五轮新增：当学生在 AI 追问后再次提交时，前端把当前题目内最近 6 条
/// 「学生发言 + AI 追问」一起上送给后端，让 LLM 不再"失忆式"重复同一个问题，
/// 并能据此判断学生本轮是否已经把题讲清楚（→ `status: completed`）。
///
/// `role` 与后端约定的字符串保持一致：
/// `student` / `xiaoming` / `daxiong` / `monitor` / `teacher` / `system`。
/// 其中 `student` 仅用于历史项，**不**会出现在 LLM 输出 `turns` 中。
class LectureHistoryItem {
  const LectureHistoryItem({
    required this.role,
    required this.displayName,
    required this.text,
    this.highlightStepIds = const [],
  });

  final String role;
  final String displayName;
  final String text;
  final List<String> highlightStepIds;

  Map<String, dynamic> toJson() => {
        'role': role,
        'displayName': displayName,
        'text': text,
        'highlightStepIds': highlightStepIds,
      };
}

/// 调用 `POST /lecture/submit` 的请求体（驼峰命名，直接经 `jsonEncode` 上送）。
class LectureSubmitRequest {
  const LectureSubmitRequest({
    required this.sectionId,
    required this.questionId,
    required this.questionPrompt,
    this.studentSpeechText = '',
    required this.steps,
    this.roundIndex = 1,
    this.history = const [],
  });

  final String sectionId;
  final String questionId;
  final String questionPrompt;
  final String studentSpeechText;
  final List<LectureStepPayload> steps;

  /// 本题第几次提交，从 1 开始。第二次（学生在回答 AI 追问后再次提交）应是 2。
  final int roundIndex;

  /// 当前题目内最近若干条对话历史（见 [LectureHistoryItem]）。
  final List<LectureHistoryItem> history;

  Map<String, dynamic> toJson() => {
        'sectionId': sectionId,
        'questionId': questionId,
        'questionPrompt': questionPrompt,
        'studentSpeechText': studentSpeechText,
        'roundIndex': roundIndex,
        'history': history.map((h) => h.toJson()).toList(growable: false),
        'steps': steps.map((s) => s.toJson()).toList(growable: false),
      };
}

class LectureStepPayload {
  const LectureStepPayload({
    required this.stepId,
    this.latex = '',
    this.plainText = '',
    this.strokeCount = 0,
    required this.boundingBox,
  });

  final String stepId;
  final String latex;
  final String plainText;
  final int strokeCount;
  final BoundingBoxPayload boundingBox;

  Map<String, dynamic> toJson() => {
        'stepId': stepId,
        'latex': latex,
        'plainText': plainText,
        'strokeCount': strokeCount,
        'boundingBox': boundingBox.toJson(),
      };
}

class BoundingBoxPayload {
  const BoundingBoxPayload({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

class LectureHintResponse {
  const LectureHintResponse({required this.turn});

  final AgentTurn turn;

  factory LectureHintResponse.fromJson(Map<String, dynamic> json) {
    final turnJson = json['turn'];
    if (turnJson is! Map<String, dynamic>) {
      return LectureHintResponse(
        turn: AgentTurn(
          role: AgentRole.teacher,
          displayName: '李老师',
          text: '',
        ),
      );
    }
    return LectureHintResponse(turn: AgentTurn.fromJson(turnJson));
  }
}

/// 单名同伴的「听懂 / 没听懂」评估（P1 `/lecture/submit` 主字段）。
class PeerAssessment {
  const PeerAssessment({
    required this.role,
    required this.displayName,
    required this.understood,
    required this.reason,
    this.highlightStepIds = const [],
  });

  final AgentRole role;
  final String displayName;
  final bool understood;
  final String reason;
  final List<String> highlightStepIds;

  factory PeerAssessment.fromJson(Map<String, dynamic> json) {
    return PeerAssessment(
      role: parseAgentRole(json['role'] as String? ?? 'xiaoming'),
      displayName: json['displayName'] as String? ?? '',
      understood: json['understood'] == true,
      reason: json['reason'] as String? ?? '',
      highlightStepIds:
          (json['highlightStepIds'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
    );
  }

  AgentTurn toReasonTurn({String? turnId}) {
    return AgentTurn(
      turnId: turnId,
      role: role,
      displayName: displayName,
      text: reason,
      highlightStepIds: highlightStepIds,
    );
  }

  LectureHistoryItem toHistoryItem() {
    return LectureHistoryItem(
      role: agentRoleWire(role),
      displayName: displayName,
      text: understood ? '（听懂了）$reason' : reason,
      highlightStepIds: highlightStepIds,
    );
  }
}

class LectureSubmitResponse {
  const LectureSubmitResponse({
    required this.questionId,
    required this.sectionId,
    required this.status,
    required this.masteryDelta,
    this.allUnderstood = false,
    this.assessments = const [],
    this.teacherSummary,
    this.turns = const [],
  });

  final String questionId;
  final String sectionId;
  final String status;
  final int masteryDelta;
  final bool allUnderstood;
  final List<PeerAssessment> assessments;
  final AgentTurn? teacherSummary;
  final List<AgentTurn> turns;

  factory LectureSubmitResponse.fromJson(Map<String, dynamic> json) {
    AgentTurn? summary;
    final summaryJson = json['teacherSummary'];
    if (summaryJson is Map<String, dynamic>) {
      summary = AgentTurn.fromJson(summaryJson);
    }
    return LectureSubmitResponse(
      questionId: json['questionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      status: json['status'] as String? ?? 'needs_explanation',
      masteryDelta: (json['masteryDelta'] as num?)?.toInt() ?? 0,
      allUnderstood: json['allUnderstood'] == true,
      assessments: (json['assessments'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PeerAssessment.fromJson)
          .toList(growable: false),
      teacherSummary: summary,
      turns: (json['turns'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AgentTurn.fromJson)
          .toList(growable: false),
    );
  }
}
