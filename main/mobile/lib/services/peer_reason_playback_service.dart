import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/lecture_models.dart';
import '../utils/tts_text.dart';

/// P2：没听懂理由的依次 TTS 播放（文字提交路径 + 可复用于 live）。
class PeerReasonPlaybackService extends ChangeNotifier {
  PeerReasonPlaybackService({http.Client? client, AudioPlayer? player})
    : _client = client ?? http.Client(),
      _player = player ?? AudioPlayer();

  final http.Client _client;
  final AudioPlayer _player;

  List<PeerAssessment> _queue = const [];
  int _index = -1;
  bool _busy = false;
  bool _disposed = false;
  int _token = 0;
  String? _lastError;

  List<PeerAssessment> get queue => _queue;
  bool get isPlaying => _busy;
  int get currentIndex => _index;
  String? get lastError => _lastError;

  PeerAssessment? get current {
    if (_index < 0 || _index >= _queue.length) return null;
    return _queue[_index];
  }

  AgentRole? get playingRole => current?.role;

  bool get hasQueue => _queue.isNotEmpty;

  bool get canPlayNext =>
      hasQueue && (!_busy || (_index >= 0 && _index < _queue.length - 1));

  void setQueue(List<PeerAssessment> assessments) {
    _queue =
        assessments
            .where((a) => !a.understood && a.reason.trim().isNotEmpty)
            .toList(growable: false);
    _index = -1;
    _lastError = null;
    notifyListeners();
  }

  void clearQueue() {
    _queue = const [];
    _index = -1;
    _lastError = null;
    notifyListeners();
  }

  /// 从第一位起自动依次播完队列。
  Future<void> playAll() async {
    if (_queue.isEmpty || _busy) return;
    await stop();
    await _playSequential(fromIndex: 0);
  }

  /// 播放下一位；若尚未开始则从第一位播。
  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    if (_busy) {
      await stop();
    }
    final next = _index < 0 ? 0 : _index + 1;
    if (next >= _queue.length) return;
    await _playSequential(fromIndex: next);
  }

  /// 播放指定同伴的理由。
  Future<void> playPeer(AgentRole role) async {
    final idx = _queue.indexWhere((a) => a.role == role);
    if (idx < 0) return;
    if (_busy) await stop();
    await _playSequential(fromIndex: idx);
  }

  Future<void> stop() async {
    _token++;
    _busy = false;
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.setVolume(1.0);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _playSequential({required int fromIndex}) async {
    final myToken = ++_token;
    _busy = true;
    _lastError = null;
    notifyListeners();

    for (var i = fromIndex; i < _queue.length; i++) {
      if (_disposed || myToken != _token) break;
      _index = i;
      notifyListeners();

      final item = _queue[i];
      final played = await _fetchAndPlay(
        text: item.reason,
        role: agentRoleWire(item.role),
        token: myToken,
      );
      if (!played || myToken != _token) break;

      try {
        await _player.onPlayerComplete.first.timeout(const Duration(minutes: 2));
      } on TimeoutException {
        break;
      } catch (_) {
        break;
      }
    }

    if (myToken == _token) {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> _fetchAndPlay({
    required String text,
    required String role,
    required int token,
  }) async {
    if (text.trim().isEmpty) return false;
    final spoken = plainTextForTts(text);
    if (spoken.isEmpty) return false;
    try {
      final resp = await _client
          .post(
            ApiConfig.uri('/tts'),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode({'text': spoken, 'role': role})),
          )
          .timeout(const Duration(seconds: 12));
      if (token != _token) return false;
      if (resp.statusCode != 200) {
        _lastError = 'TTS 请求失败 (HTTP ${resp.statusCode})';
        notifyListeners();
        return false;
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        _lastError = 'TTS 返回格式异常';
        notifyListeners();
        return false;
      }
      if (decoded['error'] != null) {
        _lastError = 'TTS：${decoded['error']}';
        notifyListeners();
        return false;
      }
      final audioBase64 = decoded['audio_base64'] as String?;
      if (audioBase64 == null || audioBase64.isEmpty) {
        _lastError = 'TTS 返回空音频';
        notifyListeners();
        return false;
      }
      final bytes = base64Decode(audioBase64);
      if (token != _token) return false;
      try {
        await _player.stop();
      } catch (_) {}
      try {
        await _player.setVolume(1.0);
      } catch (_) {}
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      return true;
    } catch (e) {
      _lastError = 'TTS 异常：$e';
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _client.close();
    _player.dispose();
    super.dispose();
  }
}
