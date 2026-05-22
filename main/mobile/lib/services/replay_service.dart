import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/round12_models.dart';
import 'auth_service.dart';

class ReplayService {
  ReplayService({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _client;
  final Duration _timeout;

  String _sessionId = '';
  String _sectionId = '';
  String _questionId = '';
  String _questionPrompt = '';
  DateTime? _startedAt;
  final List<Map<String, dynamic>> _inkTimeline = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _turnsTimeline = <Map<String, dynamic>>[];
  final List<String> _audioChunks = <String>[];

  void startSession({
    required String sessionId,
    required String sectionId,
    required String questionId,
    required String questionPrompt,
  }) {
    _sessionId = sessionId;
    _sectionId = sectionId;
    _questionId = questionId;
    _questionPrompt = questionPrompt;
    _startedAt = DateTime.now();
    _inkTimeline.clear();
    _turnsTimeline.clear();
    _audioChunks.clear();
  }

  int get _tMs {
    final start = _startedAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMilliseconds;
  }

  void appendInk(List<Map<String, dynamic>> steps) {
    if (_sessionId.isEmpty || steps.isEmpty) return;
    _inkTimeline.add({'tMs': _tMs, 'steps': steps});
  }

  void appendTurn({
    required String role,
    required String displayName,
    required String text,
  }) {
    if (_sessionId.isEmpty || text.trim().isEmpty) return;
    _turnsTimeline.add({
      'tMs': _tMs,
      'role': role,
      'displayName': displayName,
      'text': text,
    });
  }

  void appendAudioChunk(String base64Data) {
    if (_sessionId.isEmpty || base64Data.isEmpty) return;
    _audioChunks.add(base64Data);
  }

  Future<void> finishAndUpload() async {
    if (_sessionId.isEmpty) return;
    final durationMs = _tMs;
    final sessionId = _sessionId;
    final sectionId = _sectionId;
    final questionId = _questionId;
    final questionPrompt = _questionPrompt;
    final audioChunks = List<String>.unmodifiable(_audioChunks);
    final inkTimeline = List<Map<String, dynamic>>.unmodifiable(
      _inkTimeline.map(Map.unmodifiable),
    );
    final turnsTimeline = List<Map<String, dynamic>>.unmodifiable(
      _turnsTimeline.map(Map.unmodifiable),
    );
    try {
      if (!AuthService.instance.isLoggedIn) return;
      final resp = await _client
          .post(
            ApiConfig.uri('/replays'),
            headers: AuthService.instance.authHeaders(),
            body: utf8.encode(
              jsonEncode({
                'sessionId': sessionId,
                'sectionId': sectionId,
                'questionId': questionId,
                'questionPrompt': questionPrompt,
                'audioBase64Chunks': audioChunks,
                'inkTimeline': inkTimeline,
                'turnsTimeline': turnsTimeline,
                'durationMs': durationMs,
              }),
            ),
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        developer.log(
          'Replay upload failed http=${resp.statusCode}',
          name: 'ai_feynman.replay',
        );
      }
    } catch (e, st) {
      developer.log(
        'Replay upload swallowed',
        name: 'ai_feynman.replay',
        error: e,
        stackTrace: st,
      );
    } finally {
      _clearCurrentSession();
    }
  }

  void _clearCurrentSession() {
    _sessionId = '';
    _sectionId = '';
    _questionId = '';
    _questionPrompt = '';
    _startedAt = null;
    _inkTimeline.clear();
    _turnsTimeline.clear();
    _audioChunks.clear();
  }

  Future<List<ReplaySummary>> fetchParentReplays({int? studentId}) async {
    final params = <String, String>{};
    if (studentId != null && studentId > 0) {
      params['studentId'] = '$studentId';
    }
    final uri = ApiConfig.uri(
      '/parent/replays',
    ).replace(queryParameters: params);
    final decoded = await _getMap(uri);
    final raw = decoded['replays'];
    return raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(ReplaySummary.fromJson)
            .toList(growable: false)
        : const <ReplaySummary>[];
  }

  Future<Map<String, dynamic>> fetchReplay(String sessionId, {int? studentId}) {
    final params = <String, String>{};
    if (studentId != null && studentId > 0) {
      params['studentId'] = '$studentId';
    }
    return _getMap(
      ApiConfig.uri('/replays/$sessionId').replace(queryParameters: params),
    );
  }

  Future<Map<String, dynamic>> _getMap(Uri uri) async {
    await AuthService.instance.load();
    final resp = await _client
        .get(uri, headers: AuthService.instance.authHeaders())
        .timeout(_timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ReplayApiException('请求失败（HTTP ${resp.statusCode}）。');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const ReplayApiException('后端返回格式不符合契约。');
    }
    return decoded;
  }

  void close() => _client.close();
}

class ReplayApiException implements Exception {
  const ReplayApiException(this.message);
  final String message;
}
