import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/lecture_models.dart';
import '../utils/tts_text.dart';

/// P2：同伴「有话要说」理由的 TTS。
///
/// 评估结果到达后后台预合成 mp3；学生点头像展开时相当于按播放键，
/// 不再在点击瞬间才请求 `/tts`。
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
  AgentRole? _playingRoleOverride;

  /// 预合成缓存：`roleWire:spokenText` → mp3 bytes。
  final Map<String, Uint8List> _audioCache = {};
  final Set<String> _prefetchInFlight = {};
  final Set<String> _prefetchFailed = {};

  List<PeerAssessment> get queue => _queue;
  bool get isPlaying => _busy;
  int get currentIndex => _index;
  String? get lastError => _lastError;

  PeerAssessment? get current {
    if (_index < 0 || _index >= _queue.length) return null;
    return _queue[_index];
  }

  AgentRole? get playingRole {
    if (!_busy) return null;
    return _playingRoleOverride ?? current?.role;
  }

  bool get hasQueue => _queue.isNotEmpty;

  bool get canPlayNext =>
      hasQueue && (!_busy || (_index >= 0 && _index < _queue.length - 1));

  String _cacheKey(String roleWire, String text) {
    final spoken = plainTextForTts(text);
    return '$roleWire:$spoken';
  }

  bool hasCachedFor({required AgentRole role, required String text}) {
    if (text.trim().isEmpty) return false;
    return _audioCache.containsKey(_cacheKey(agentRoleWire(role), text));
  }

  bool isPrefetching({required AgentRole role, required String text}) {
    if (text.trim().isEmpty) return false;
    return _prefetchInFlight.contains(_cacheKey(agentRoleWire(role), text));
  }

  /// 「有话要说」chip 是否应展示：预合成成功；失败则仍展示以便回退现场合成。
  bool isSpeakChipReady({required AgentRole role, required String text}) {
    if (text.trim().isEmpty) return false;
    final key = _cacheKey(agentRoleWire(role), text);
    return _audioCache.containsKey(key) || _prefetchFailed.contains(key);
  }

  void setQueue(List<PeerAssessment> assessments) {
    _queue =
        assessments
            .where((a) => !a.understood && a.reason.trim().isNotEmpty)
            .toList(growable: false);
    _index = -1;
    _playingRoleOverride = null;
    _lastError = null;
    notifyListeners();
    unawaited(_prefetchQueueItems());
  }

  void clearQueue() {
    _queue = const [];
    _index = -1;
    _playingRoleOverride = null;
    _lastError = null;
    _clearPrefetchCache();
    notifyListeners();
  }

  void _clearPrefetchCache() {
    _audioCache.clear();
    _prefetchInFlight.clear();
    _prefetchFailed.clear();
  }

  /// 单条同伴评估到达时预合成（流式 peer_assessment_item 路径）。
  Future<void> prefetchAssessment(PeerAssessment assessment) async {
    if (assessment.understood || assessment.reason.trim().isEmpty) return;
    await prefetchText(role: assessment.role, text: assessment.reason);
  }

  /// 批量预合成当前队列里所有「有话要说」理由。
  Future<void> _prefetchQueueItems() async {
    if (_queue.isEmpty || _disposed) return;
    await Future.wait(_queue.map(prefetchAssessment));
  }

  /// 预合成任意同伴/老师文案（peerReplies、李老师提示等）。
  Future<void> prefetchText({
    required AgentRole role,
    required String text,
  }) async {
    if (_disposed || text.trim().isEmpty) return;
    final roleWire = agentRoleWire(role);
    final key = _cacheKey(roleWire, text);
    if (_audioCache.containsKey(key) || _prefetchInFlight.contains(key)) {
      return;
    }
    _prefetchInFlight.add(key);
    notifyListeners();
    try {
      final bytes = await _fetchAudioBytes(text: text, role: roleWire);
      if (_disposed) return;
      if (bytes != null) {
        _audioCache[key] = bytes;
        _prefetchFailed.remove(key);
      } else {
        _prefetchFailed.add(key);
      }
      notifyListeners();
    } finally {
      _prefetchInFlight.remove(key);
      if (!_disposed) notifyListeners();
    }
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

  /// 只播放 [role] 对应的一位同伴，**不**连带播后面的人。
  Future<void> playPeer(AgentRole role) async {
    final idx = _queue.indexWhere((a) => a.role == role);
    if (idx < 0) return;
    if (_busy) await stop();
    await _playSingleAt(idx);
  }

  /// 播放任意文案（李老师提示 / 未入队的单条气泡）。
  Future<void> playText({
    required AgentRole role,
    required String text,
  }) async {
    if (text.trim().isEmpty) return;
    if (_busy) await stop();
    final myToken = ++_token;
    _busy = true;
    _index = -1;
    _playingRoleOverride = role;
    _lastError = null;
    notifyListeners();

    final played = await _fetchAndPlay(
      text: text,
      role: agentRoleWire(role),
      token: myToken,
    );
    if (!played || myToken != _token) {
      if (myToken == _token) {
        _busy = false;
        _playingRoleOverride = null;
        notifyListeners();
      }
      return;
    }

    await _awaitPlaybackComplete(myToken);
    if (myToken == _token) {
      _busy = false;
      _playingRoleOverride = null;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _token++;
    _busy = false;
    _playingRoleOverride = null;
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.setVolume(1.0);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _playSingleAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final myToken = ++_token;
    _busy = true;
    _playingRoleOverride = null;
    _lastError = null;
    _index = index;
    notifyListeners();

    final item = _queue[index];
    final played = await _fetchAndPlay(
      text: item.reason,
      role: agentRoleWire(item.role),
      token: myToken,
    );
    if (!played || myToken != _token) {
      if (myToken == _token) {
        _busy = false;
        notifyListeners();
      }
      return;
    }

    await _awaitPlaybackComplete(myToken);
    if (myToken == _token) {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _playSequential({required int fromIndex}) async {
    final myToken = ++_token;
    _busy = true;
    _playingRoleOverride = null;
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

  Future<void> _awaitPlaybackComplete(int token) async {
    try {
      await _player.onPlayerComplete.first.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      // swallow
    } catch (_) {
      // swallow
    }
  }

  Future<Uint8List?> _fetchAudioBytes({
    required String text,
    required String role,
  }) async {
    if (text.trim().isEmpty) return null;
    final spoken = plainTextForTts(text);
    if (spoken.isEmpty) return null;
    try {
      final resp = await _client
          .post(
            ApiConfig.uri('/tts'),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode({'text': spoken, 'role': role})),
          )
          .timeout(const Duration(seconds: 12));
      if (_disposed) return null;
      if (resp.statusCode != 200) {
        _lastError = 'TTS 请求失败 (HTTP ${resp.statusCode})';
        notifyListeners();
        return null;
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        _lastError = 'TTS 返回格式异常';
        notifyListeners();
        return null;
      }
      if (decoded['error'] != null) {
        _lastError = 'TTS：${decoded['error']}';
        notifyListeners();
        return null;
      }
      final audioBase64 = decoded['audio_base64'] as String?;
      if (audioBase64 == null || audioBase64.isEmpty) {
        _lastError = 'TTS 返回空音频';
        notifyListeners();
        return null;
      }
      return base64Decode(audioBase64);
    } catch (e) {
      _lastError = 'TTS 异常：$e';
      notifyListeners();
      return null;
    }
  }

  Future<bool> _playBytes(Uint8List bytes, int token) async {
    if (token != _token || _disposed) return false;
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.setVolume(1.0);
    } catch (_) {}
    if (token != _token) return false;
    await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    return true;
  }

  Future<bool> _fetchAndPlay({
    required String text,
    required String role,
    required int token,
  }) async {
    if (text.trim().isEmpty) return false;
    final key = _cacheKey(role, text);
    final cached = _audioCache[key];
    if (cached != null) {
      return _playBytes(cached, token);
    }
    final bytes = await _fetchAudioBytes(text: text, role: role);
    if (bytes == null || token != _token) return false;
    _audioCache[key] = bytes;
    return _playBytes(bytes, token);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _clearPrefetchCache();
    _client.close();
    _player.dispose();
    super.dispose();
  }
}
