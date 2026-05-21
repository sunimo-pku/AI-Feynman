import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../config/api_config.dart';
import '../data/live_lecture_events.dart';
import 'auth_service.dart';
import 'ocr_service.dart';

/// 实时讲题服务（第九轮）。
///
/// 责任：
///   * 维护 `ws://.../lecture/live` 的连接 / 重连状态；
///   * 把 [LiveClientEvent] 序列化为 JSON 发到后端，把后端 JSON
///     反序列化成 [LiveServerEvent]；
///   * 提供"发送 audio 字节"快捷方法 [sendAudioBytes]，内部 base64 编码
///     + seq 自增 + 防止 closed channel；
///   * 在收到 `agent_turn_done` 或 [requestTts] 时调用现有 `POST /tts`
///     拿到 mp3 base64 → 用 [AudioPlayer] 播放；
///   * 学生开口 / 落笔时调用 [stopTts]（带快速淡出 TODO）。
///
/// 错误语义：
///   * 任何 WebSocket / HTTP / 播放器异常都**只**写到 [errors] 流，不抛；
///     UI 据此切到"连接断开"提示但保留白板；
///   * [dispose] 幂等。
class LiveLectureService {
  LiveLectureService({
    http.Client? httpClient,
    AudioPlayer? audioPlayer,
    OcrService? ocrService,
  })  : _httpClient = httpClient ?? http.Client(),
        _audioPlayer = audioPlayer ?? AudioPlayer(),
        _ocrService = ocrService ?? OcrService();

  final http.Client _httpClient;
  final AudioPlayer _audioPlayer;
  final OcrService _ocrService;

  /// 第十轮：当前题目相关上下文，供 [sendInkSnapshot] 调用 OCR 兜底。
  /// 由调用方在 [connectAndStart] 时一并传入。
  String _currentSectionId = '';
  String _currentQuestionId = '';
  List<String> _currentReferenceSteps = const <String>[];

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  bool _isConnected = false;
  bool _disposed = false;
  int _audioSeq = 0;
  String _sessionId = '';

  /// 第十轮：TTS 淡出相关。
  ///
  /// `_ttsFadeTimer` 在 [stopTts] 时启动 200ms 渐降：每 25ms tick 调
  /// `setVolume(...)`，比直接 `stop()` 自然得多；终止后才真正
  /// `_audioPlayer.stop()`。
  ///
  /// `_currentTtsToken` 用来防御「学生连点两次打断」时第二个 fade timer
  /// 复用 audioplayers 实例，造成音量被反复 reset 的怪异行为。
  Timer? _ttsFadeTimer;
  int _currentTtsToken = 0;

  final _eventsController = StreamController<LiveServerEvent>.broadcast();
  final _connectionController = StreamController<LiveConnectionState>.broadcast();
  final _errorsController = StreamController<String>.broadcast();
  final _ttsStateController = StreamController<TtsState>.broadcast();

  Stream<LiveServerEvent> get events => _eventsController.stream;
  Stream<LiveConnectionState> get connectionState =>
      _connectionController.stream;
  Stream<String> get errors => _errorsController.stream;
  Stream<TtsState> get ttsState => _ttsStateController.stream;

  bool get isConnected => _isConnected;
  String get sessionId => _sessionId;

  /// 连接 WS、立即发送 session_start。
  ///
  /// 返回 true 表示 WS 握手成功并已发出 session_start；false 表示
  /// 当下无法连接 —— UI 应当回落到 `/lecture/submit` 非实时闭环。
  Future<bool> connectAndStart({
    required String sessionId,
    required String sectionId,
    required String questionId,
    required String questionPrompt,
    List<String> referenceSteps = const <String>[],
  }) async {
    if (_disposed) return false;
    _currentSectionId = sectionId;
    _currentQuestionId = questionId;
    _currentReferenceSteps = List.unmodifiable(referenceSteps);
    if (_isConnected) {
      // 已连接：发送 session_start 切换到新会话。
      _sessionId = sessionId;
      _audioSeq = 0;
      _sendJson(LiveClientEvent.sessionStart(
        sessionId: sessionId,
        sectionId: sectionId,
        questionId: questionId,
        questionPrompt: questionPrompt,
      ));
      return true;
    }
    try {
      final uri = _buildWsUri();
      _channel = WebSocketChannel.connect(uri);
      // 一些平台（Web）的 channel.ready 不存在，做兼容
      try {
        await _channel!.ready;
      } catch (_) {
        // 部分实现没有 ready；继续，错误会从 onError 透出
      }
      _channelSub = _channel!.stream.listen(
        _onWsMessage,
        onError: (Object err, StackTrace st) {
          _emitError('WebSocket 异常：$err');
          _markDisconnected();
        },
        onDone: () {
          _markDisconnected();
        },
        cancelOnError: false,
      );
      _isConnected = true;
      _sessionId = sessionId;
      _audioSeq = 0;
      _connectionController.add(LiveConnectionState.connected);
      _sendJson(LiveClientEvent.sessionStart(
        sessionId: sessionId,
        sectionId: sectionId,
        questionId: questionId,
        questionPrompt: questionPrompt,
      ));
      return true;
    } catch (e) {
      _emitError('连接后端失败：$e');
      _markDisconnected();
      return false;
    }
  }

  /// 把一段 PCM16 字节流编码后通过 audio_chunk 事件发送。
  void sendAudioBytes(Uint8List data, {int sampleRate = 16000}) {
    if (!_isConnected || _sessionId.isEmpty || data.isEmpty) return;
    final seq = _audioSeq++;
    final base64Data = base64Encode(data);
    _sendJson(LiveClientEvent.audioChunk(
      sessionId: _sessionId,
      seq: seq,
      base64Data: base64Data,
      sampleRate: sampleRate,
      format: 'pcm16',
    ));
  }

  void sendInkSnapshot(List<Map<String, dynamic>> steps) {
    if (!_isConnected || _sessionId.isEmpty) return;
    // 第十轮：snapshot 上送之前先**异步**走一遍 /ocr/ink，把 latex/plainText
    // 补进每个 step；OCR 失败不影响主流程，仍发空 latex 上送。
    if (steps.isEmpty) {
      _sendJson(LiveClientEvent.inkSnapshot(
        sessionId: _sessionId,
        steps: steps,
      ));
      return;
    }
    unawaited(_enrichAndSendSnapshot(steps));
  }

  Future<void> _enrichAndSendSnapshot(List<Map<String, dynamic>> steps) async {
    // 若调用方已经手动填了 latex / plainText（譬如学生手敲），保留它；
    // 仅对空字段做覆盖。
    List<Map<String, dynamic>> enriched = steps;
    final needsOcr = steps.any((s) {
      final latex = (s['latex'] as String? ?? '').trim();
      final plain = (s['plainText'] as String? ?? '').trim();
      return latex.isEmpty && plain.isEmpty;
    });
    if (needsOcr && _currentSectionId.isNotEmpty) {
      try {
        final guesses = await _ocrService.recognize(
          sectionId: _currentSectionId,
          questionId: _currentQuestionId,
          referenceSteps: _currentReferenceSteps,
          steps: steps
              .map((s) => OcrStepInput(
                    stepId: s['stepId'] as String? ?? '',
                    strokeCount: (s['strokeCount'] as int?) ?? 0,
                    boundingBox: s['boundingBox'] as Map<String, dynamic>?,
                    imageBase64: s['imageBase64'] as String? ?? '',
                  ))
              .toList(growable: false),
        );
        if (guesses != null && guesses.isNotEmpty) {
          final byStep = {for (final g in guesses) g.stepId: g};
          enriched = steps
              .map((s) => <String, dynamic>{
                    ...s,
                    if ((s['latex'] as String? ?? '').isEmpty)
                      'latex': byStep[s['stepId']]?.latex ?? '',
                    if ((s['plainText'] as String? ?? '').isEmpty)
                      'plainText': byStep[s['stepId']]?.plainText ?? '',
                  })
              .toList(growable: false);
        }
      } catch (e) {
        _emitError('OCR 调用失败：$e');
      }
    }
    if (!_isConnected || _sessionId.isEmpty) return;
    _sendJson(LiveClientEvent.inkSnapshot(
      sessionId: _sessionId,
      steps: enriched,
    ));
  }

  void sendPauseDetected({required int silenceMs}) {
    if (!_isConnected || _sessionId.isEmpty) return;
    _sendJson(LiveClientEvent.pauseDetected(
      sessionId: _sessionId,
      silenceMs: silenceMs,
    ));
  }

  void sendStudentInterrupt({String reason = 'voice'}) {
    if (!_isConnected || _sessionId.isEmpty) return;
    _sendJson(LiveClientEvent.studentInterrupt(
      sessionId: _sessionId,
      reason: reason,
    ));
  }

  Future<void> endSession() async {
    if (_isConnected && _sessionId.isNotEmpty) {
      _sendJson(LiveClientEvent.sessionEnd(sessionId: _sessionId));
    }
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {
      /* swallow */
    }
    _markDisconnected();
  }

  /// 调用现有 `POST /tts`，把 [text] 合成 mp3 → 播放。
  ///
  /// 设计：
  ///   * 第九轮 brief 第 11 节允许"等 agent_turn_done 后再 TTS"；
  ///   * 学生开口 / 落笔时调用 [stopTts]，目前是快速 stop()，
  ///     TODO：接入 200ms 淡出（audioplayers 暂不直接支持 fade，
  ///     需要平台侧实现或用 just_audio）。
  ///   * 任意失败都只走 [errors] / [ttsState]，不抛。
  Future<void> requestTts(String text, {String role = ''}) async {
    if (_disposed || text.trim().isEmpty) return;
    try {
      final uri = ApiConfig.uri('/tts');
      final resp = await _httpClient
          .post(
            uri,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode({'text': text, 'role': role})),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        _emitError('TTS 请求失败 (HTTP ${resp.statusCode})');
        return;
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        _emitError('TTS 返回格式异常');
        return;
      }
      if (decoded['error'] != null) {
        _emitError('TTS 服务：${decoded['error']}');
        return;
      }
      final audioBase64 = decoded['audio_base64'] as String?;
      if (audioBase64 == null || audioBase64.isEmpty) {
        _emitError('TTS 返回空音频');
        return;
      }
      final bytes = base64Decode(audioBase64);
      _ttsFadeTimer?.cancel();
      _ttsFadeTimer = null;
      final myToken = ++_currentTtsToken;
      try {
        await _audioPlayer.stop();
      } catch (_) {}
      try {
        // 把音量复位到 1.0；上一轮 stopTts 的渐隐可能把音量调到了 0。
        await _audioPlayer.setVolume(1.0);
      } catch (_) {}
      if (myToken != _currentTtsToken) return; // 中途被新一轮覆盖
      _ttsStateController.add(TtsState.playing);
      await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      // 监听播放完成：audioplayers 的 onPlayerComplete 是 Stream
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (!_ttsStateController.isClosed) {
          _ttsStateController.add(TtsState.idle);
        }
      });
    } catch (e) {
      _emitError('TTS 异常：$e');
      _ttsStateController.add(TtsState.idle);
    }
  }

  /// 学生打断 AI 播放。第十轮：实现 ~200ms 渐隐 fade-out。
  ///
  /// `audioplayers` 6.x 没有原生 fade API；这里手动按 25ms tick 调
  /// `setVolume(...)` 把音量从 1.0 平滑降到 0，然后真正 `stop()`。
  ///
  /// 调用幂等：连续两次 stopTts 第二个会直接 fast-forward 到 0 + stop。
  ///
  /// 不阻塞调用方：方法本身仍是 Future，但内部 tick 走异步 Timer，
  /// 学生白板继续可写（brief 第 11 节）。
  Future<void> stopTts({Duration fadeDuration = const Duration(milliseconds: 220)}) async {
    final myToken = ++_currentTtsToken;
    _ttsFadeTimer?.cancel();
    final stepMs = 25;
    final steps = (fadeDuration.inMilliseconds / stepMs).ceil().clamp(1, 64);
    var current = steps;
    final completer = Completer<void>();
    _ttsFadeTimer = Timer.periodic(Duration(milliseconds: stepMs), (t) async {
      if (myToken != _currentTtsToken) {
        t.cancel();
        completer.complete();
        return;
      }
      current -= 1;
      final v = (current / steps).clamp(0.0, 1.0).toDouble();
      try {
        await _audioPlayer.setVolume(v);
      } catch (_) {
        /* swallow — audioplayers 在 Web/某些平台可能 setVolume 失败 */
      }
      if (current <= 0) {
        t.cancel();
        try {
          await _audioPlayer.stop();
        } catch (_) {}
        try {
          await _audioPlayer.setVolume(1.0);
        } catch (_) {}
        if (!_ttsStateController.isClosed) {
          _ttsStateController.add(TtsState.idle);
        }
        if (!completer.isCompleted) completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> dispose() async {
    _disposed = true;
    _ttsFadeTimer?.cancel();
    _ttsFadeTimer = null;
    try {
      await _channelSub?.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    try {
      await _audioPlayer.dispose();
    } catch (_) {}
    try {
      _httpClient.close();
    } catch (_) {}
    try {
      _ocrService.close();
    } catch (_) {}
    await _eventsController.close();
    await _connectionController.close();
    await _errorsController.close();
    await _ttsStateController.close();
  }

  // ============================================================== //
  // 内部
  // ============================================================== //

  Uri _buildWsUri() {
    final base = ApiConfig.baseUrl;
    String wsBase;
    if (base.startsWith('https://')) {
      wsBase = 'wss://${base.substring('https://'.length)}';
    } else if (base.startsWith('http://')) {
      wsBase = 'ws://${base.substring('http://'.length)}';
    } else {
      wsBase = 'ws://$base';
    }
    // 第十轮：登录后把 JWT 带在 query token，让后端 _extract_user_from_ws
    // 解出当前 student，把实时会话写进 LectureSessionRecord 并更新进度。
    // 未登录时不带，后端走匿名 demo 路径，不影响第九轮链路。
    final token = AuthService.instance.currentToken;
    final query = token.isNotEmpty ? '?token=${Uri.encodeQueryComponent(token)}' : '';
    return Uri.parse('$wsBase/lecture/live$query');
  }

  void _sendJson(Map<String, dynamic> payload) {
    final sink = _channel?.sink;
    if (sink == null) return;
    try {
      sink.add(jsonEncode(payload));
    } catch (e) {
      _emitError('发送事件失败：$e');
      _markDisconnected();
    }
  }

  void _onWsMessage(dynamic message) {
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final event = LiveServerEvent.fromJson(decoded);
      if (!_eventsController.isClosed) {
        _eventsController.add(event);
      }
    } catch (e) {
      _emitError('解析 WS 事件失败：$e');
    }
  }

  void _markDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    _audioSeq = 0;
    if (!_connectionController.isClosed) {
      _connectionController.add(LiveConnectionState.disconnected);
    }
  }

  void _emitError(String message) {
    if (kDebugMode) {
      debugPrint('[LiveLectureService] $message');
    }
    if (!_errorsController.isClosed) {
      _errorsController.add(message);
    }
  }
}

enum LiveConnectionState { disconnected, connected }

enum TtsState { idle, playing }
