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
}

/// 调用 `POST /lecture/submit` 的请求体（驼峰命名，直接经 `jsonEncode` 上送）。
class LectureSubmitRequest {
  const LectureSubmitRequest({
    required this.sectionId,
    required this.questionId,
    required this.questionPrompt,
    this.studentSpeechText = '',
    required this.steps,
  });

  final String sectionId;
  final String questionId;
  final String questionPrompt;
  final String studentSpeechText;
  final List<LectureStepPayload> steps;

  Map<String, dynamic> toJson() => {
        'sectionId': sectionId,
        'questionId': questionId,
        'questionPrompt': questionPrompt,
        'studentSpeechText': studentSpeechText,
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

class LectureSubmitResponse {
  const LectureSubmitResponse({
    required this.questionId,
    required this.sectionId,
    required this.status,
    required this.masteryDelta,
    required this.turns,
  });

  final String questionId;
  final String sectionId;
  final String status;
  final int masteryDelta;
  final List<AgentTurn> turns;

  factory LectureSubmitResponse.fromJson(Map<String, dynamic> json) {
    return LectureSubmitResponse(
      questionId: json['questionId'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      status: json['status'] as String? ?? 'needs_explanation',
      masteryDelta: (json['masteryDelta'] as num?)?.toInt() ?? 0,
      turns: (json['turns'] as List<dynamic>? ?? const [])
          .map((e) => AgentTurn.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}
