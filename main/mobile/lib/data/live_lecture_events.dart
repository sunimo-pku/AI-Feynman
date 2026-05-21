/// 实时讲题 WebSocket 事件模型（第九轮）。
///
/// 与 `main/app/services/live_lecture_session.py` 约定的字符串常量
/// 1:1 对齐；任意字段加减都要 backend / frontend 同步改。
///
/// 设计取舍：
///   * **不**用 `freezed` / `json_serializable` 生成代码。事件协议字段
///     稀少且语义稳定，手写 fromJson/toJson 既不增加心智负担，又能省去
///     codegen 引入的 build_runner 工具链。
///   * 解析层故意"宽进严出"：来路不明的事件被映射成
///     [LiveServerEventType.unknown]，不会抛异常 —— brief 第 13 节
///     "WebSocket 中途断开" / "ASR 窗口失败"等错误都要求"不破坏白板继续
///     使用"，宁可静默忽略也不要让一条坏 JSON 把整个会话杀掉。
library;

/// 客户端 → 服务端事件类型。
enum LiveClientEventType {
  sessionStart('session_start'),
  audioChunk('audio_chunk'),
  inkSnapshot('ink_snapshot'),
  pauseDetected('pause_detected'),
  studentInterrupt('student_interrupt'),
  sessionEnd('session_end');

  const LiveClientEventType(this.wire);
  final String wire;
}

/// 服务端 → 客户端事件类型。
enum LiveServerEventType {
  listening,
  asrSegment,
  thinking,
  agentTurnStart,
  agentTurnDelta,
  agentTurnDone,
  roundDone,
  warning,
  error,
  unknown,
}

LiveServerEventType parseLiveServerEventType(String raw) {
  switch (raw) {
    case 'listening':
      return LiveServerEventType.listening;
    case 'asr_segment':
      return LiveServerEventType.asrSegment;
    case 'thinking':
      return LiveServerEventType.thinking;
    case 'agent_turn_start':
      return LiveServerEventType.agentTurnStart;
    case 'agent_turn_delta':
      return LiveServerEventType.agentTurnDelta;
    case 'agent_turn_done':
      return LiveServerEventType.agentTurnDone;
    case 'round_done':
      return LiveServerEventType.roundDone;
    case 'warning':
      return LiveServerEventType.warning;
    case 'error':
      return LiveServerEventType.error;
    default:
      return LiveServerEventType.unknown;
  }
}

/// 服务端事件的强类型 sealed-class 风格表达。
///
/// 每个具体事件子类只持有"对前端有意义"的字段；`sessionId` 在容器
/// [LiveServerEvent] 上统一持有。
abstract class LiveServerPayload {
  const LiveServerPayload();
}

class LiveListeningPayload extends LiveServerPayload {
  const LiveListeningPayload();
}

class LiveAsrSegmentPayload extends LiveServerPayload {
  const LiveAsrSegmentPayload({required this.text});
  final String text;
}

class LiveThinkingPayload extends LiveServerPayload {
  const LiveThinkingPayload();
}

class LiveAgentTurnStartPayload extends LiveServerPayload {
  const LiveAgentTurnStartPayload({
    required this.turnId,
    required this.role,
    required this.displayName,
    required this.highlightStepIds,
  });

  final String turnId;
  final String role;
  final String displayName;
  final List<String> highlightStepIds;
}

class LiveAgentTurnDeltaPayload extends LiveServerPayload {
  const LiveAgentTurnDeltaPayload({
    required this.turnId,
    required this.delta,
  });

  final String turnId;
  final String delta;
}

class LiveAgentTurnDonePayload extends LiveServerPayload {
  const LiveAgentTurnDonePayload({required this.turnId});
  final String turnId;
}

class LiveRoundDonePayload extends LiveServerPayload {
  const LiveRoundDonePayload({
    required this.status,
    required this.masteryDelta,
  });

  final String status;
  final int masteryDelta;
}

class LiveWarningPayload extends LiveServerPayload {
  const LiveWarningPayload({required this.message});
  final String message;
}

class LiveErrorPayload extends LiveServerPayload {
  const LiveErrorPayload({required this.message});
  final String message;
}

class LiveUnknownPayload extends LiveServerPayload {
  const LiveUnknownPayload({required this.rawType});
  final String rawType;
}

class LiveServerEvent {
  const LiveServerEvent({
    required this.type,
    required this.sessionId,
    required this.payload,
  });

  final LiveServerEventType type;
  final String sessionId;
  final LiveServerPayload payload;

  static LiveServerEvent fromJson(Map<String, dynamic> json) {
    final rawType = json['type']?.toString() ?? '';
    final sessionId = json['sessionId']?.toString() ?? '';
    final type = parseLiveServerEventType(rawType);
    final payload = _payloadFromJson(type, rawType, json);
    return LiveServerEvent(type: type, sessionId: sessionId, payload: payload);
  }

  static LiveServerPayload _payloadFromJson(
    LiveServerEventType type,
    String rawType,
    Map<String, dynamic> json,
  ) {
    switch (type) {
      case LiveServerEventType.listening:
        return const LiveListeningPayload();
      case LiveServerEventType.asrSegment:
        return LiveAsrSegmentPayload(text: (json['text'] as String?) ?? '');
      case LiveServerEventType.thinking:
        return const LiveThinkingPayload();
      case LiveServerEventType.agentTurnStart:
        return LiveAgentTurnStartPayload(
          turnId: (json['turnId'] as String?) ?? '',
          role: (json['role'] as String?) ?? 'system',
          displayName: (json['displayName'] as String?) ?? '',
          highlightStepIds: (json['highlightStepIds'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
        );
      case LiveServerEventType.agentTurnDelta:
        return LiveAgentTurnDeltaPayload(
          turnId: (json['turnId'] as String?) ?? '',
          delta: (json['delta'] as String?) ?? '',
        );
      case LiveServerEventType.agentTurnDone:
        return LiveAgentTurnDonePayload(
          turnId: (json['turnId'] as String?) ?? '',
        );
      case LiveServerEventType.roundDone:
        final delta = json['masteryDelta'];
        return LiveRoundDonePayload(
          status: (json['status'] as String?) ?? 'needs_explanation',
          masteryDelta: delta is num ? delta.toInt() : 0,
        );
      case LiveServerEventType.warning:
        return LiveWarningPayload(
          message: (json['message'] as String?) ?? 'warning',
        );
      case LiveServerEventType.error:
        return LiveErrorPayload(
          message: (json['message'] as String?) ?? 'error',
        );
      case LiveServerEventType.unknown:
        return LiveUnknownPayload(rawType: rawType);
    }
  }
}

/// 客户端发给后端的事件构造器。各方法返回 `Map<String, dynamic>` 而不是
/// 字符串，调用方 (`LiveLectureService`) 决定怎样序列化（默认 jsonEncode）。
class LiveClientEvent {
  const LiveClientEvent._();

  static Map<String, dynamic> sessionStart({
    required String sessionId,
    required String sectionId,
    required String questionId,
    required String questionPrompt,
  }) {
    return {
      'type': LiveClientEventType.sessionStart.wire,
      'sessionId': sessionId,
      'sectionId': sectionId,
      'questionId': questionId,
      'questionPrompt': questionPrompt,
    };
  }

  static Map<String, dynamic> audioChunk({
    required String sessionId,
    required int seq,
    required String base64Data,
    int sampleRate = 16000,
    String format = 'pcm16',
  }) {
    return {
      'type': LiveClientEventType.audioChunk.wire,
      'sessionId': sessionId,
      'seq': seq,
      'format': format,
      'sampleRate': sampleRate,
      'base64': base64Data,
    };
  }

  static Map<String, dynamic> inkSnapshot({
    required String sessionId,
    required List<Map<String, dynamic>> steps,
  }) {
    return {
      'type': LiveClientEventType.inkSnapshot.wire,
      'sessionId': sessionId,
      'steps': steps,
    };
  }

  static Map<String, dynamic> pauseDetected({
    required String sessionId,
    required int silenceMs,
  }) {
    return {
      'type': LiveClientEventType.pauseDetected.wire,
      'sessionId': sessionId,
      'silenceMs': silenceMs,
    };
  }

  static Map<String, dynamic> studentInterrupt({
    required String sessionId,
    required String reason,
  }) {
    return {
      'type': LiveClientEventType.studentInterrupt.wire,
      'sessionId': sessionId,
      'reason': reason,
    };
  }

  static Map<String, dynamic> sessionEnd({required String sessionId}) {
    return {
      'type': LiveClientEventType.sessionEnd.wire,
      'sessionId': sessionId,
    };
  }
}
