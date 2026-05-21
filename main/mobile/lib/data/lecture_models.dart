/// 讲题 / 多 Agent 对话相关的纯数据模型。
///
/// V1 阶段仅在前端构造 Mock 数据，后续会替换为后端 API（保持字段不变）。
library;

enum AgentRole {
  xiaoming,
  daxiong,
  classLeader,
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
    case 'teacher':
      return AgentRole.teacher;
    default:
      return AgentRole.system;
  }
}

class AgentTurn {
  const AgentTurn({
    required this.role,
    required this.displayName,
    required this.text,
    this.highlightStepIds = const [],
  });

  final AgentRole role;
  final String displayName;
  final String text;
  final List<String> highlightStepIds;

  factory AgentTurn.fromJson(Map<String, dynamic> json) {
    return AgentTurn(
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

class LectureDiscussion {
  const LectureDiscussion({
    required this.questionId,
    required this.turns,
    required this.summary,
  });

  final String questionId;
  final List<AgentTurn> turns;
  final String summary;
}
