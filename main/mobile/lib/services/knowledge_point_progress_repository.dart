import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/knowledge_point_progress_models.dart';

/// 知识点掌握度（星级）本地仓库。
class KnowledgePointProgressRepository extends ChangeNotifier {
  KnowledgePointProgressRepository._();

  static final KnowledgePointProgressRepository instance =
      KnowledgePointProgressRepository._();

  static const String _storagePrefix = 'ai_feynman.knowledge_point_progress.v1';
  String _namespace = 'guest';
  String get _storageKey => '$_storagePrefix.$_namespace';

  final Map<String, KnowledgePointProgress> _cache =
      <String, KnowledgePointProgress>{};

  bool _loaded = false;
  Future<void>? _pendingLoad;
  Future<void> _writeQueue = Future<void>.value();

  @visibleForTesting
  SharedPreferences? testPrefsOverride;

  Future<SharedPreferences> _obtainPrefs() async {
    if (testPrefsOverride != null) return testPrefsOverride!;
    return SharedPreferences.getInstance();
  }

  Future<void> load() {
    if (_loaded) return Future.value();
    final pending = _pendingLoad;
    if (pending != null) return pending;
    final future = _loadInternal();
    _pendingLoad = future;
    return future;
  }

  Future<void> _loadInternal() async {
    try {
      final prefs = await _obtainPrefs();
      final raw = prefs.getString(_storageKey);
      _cache.clear();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            Map<String, dynamic>? map;
            if (value is Map<String, dynamic>) {
              map = value;
            } else if (value is Map) {
              map = value.cast<String, dynamic>();
            }
            if (map == null) return;
            final progress = KnowledgePointProgress.fromJson(map);
            if (progress.knowledgePointId.isNotEmpty) {
              _cache[progress.knowledgePointId] = progress;
            }
          });
        }
      }
      _loaded = true;
    } catch (e, st) {
      developer.log(
        'KnowledgePointProgressRepository load failed; treating as empty',
        name: 'ai_feynman.kp_progress',
        error: e,
        stackTrace: st,
      );
      _cache.clear();
      _loaded = true;
    } finally {
      _pendingLoad = null;
      notifyListeners();
    }
  }

  KnowledgePointProgress progressFor(String knowledgePointId) {
    return _cache[knowledgePointId] ??
        KnowledgePointProgress.empty(knowledgePointId);
  }

  bool get isLoaded => _loaded;

  Future<void> switchUser(String namespace) async {
    final next = namespace.trim().isEmpty ? 'guest' : namespace.trim();
    if (next == _namespace && _loaded) return;
    _namespace = next;
    _cache.clear();
    _loaded = false;
    _pendingLoad = null;
    await load();
  }

  void clearActiveUser() {
    _namespace = 'guest';
    _cache.clear();
    _loaded = true;
    _pendingLoad = null;
    _writeQueue = Future<void>.value();
    notifyListeners();
  }

  Future<({KnowledgePointProgress next, int starGain})> applyRound({
    required String knowledgePointId,
    required String status,
    required int masteryDelta,
    required int peersUnderstood,
    int totalPeers = 3,
    DateTime? when,
  }) async {
    if (knowledgePointId.isEmpty) {
      return (next: KnowledgePointProgress.empty(''), starGain: 0);
    }
    final completer =
        Completer<({KnowledgePointProgress next, int starGain})>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        if (!_loaded) await _loadInternal();
        final current =
            _cache[knowledgePointId] ??
            KnowledgePointProgress.empty(knowledgePointId);
        final result = current.applyRound(
          status: status,
          masteryDelta: masteryDelta,
          peersUnderstood: peersUnderstood,
          totalPeers: totalPeers,
          when: when,
        );
        _cache[knowledgePointId] = result.next;
        await _save();
        notifyListeners();
        completer.complete(result);
      } catch (e, st) {
        developer.log(
          'KnowledgePointProgressRepository applyRound failed: kp=$knowledgePointId',
          name: 'ai_feynman.kp_progress',
          error: e,
          stackTrace: st,
        );
        final fallback =
            _cache[knowledgePointId] ??
            KnowledgePointProgress.empty(knowledgePointId);
        completer.complete((next: fallback, starGain: 0));
      }
    });
    return completer.future;
  }

  Future<void> _save() async {
    try {
      final prefs = await _obtainPrefs();
      final payload = <String, dynamic>{};
      _cache.forEach((key, value) {
        payload[key] = value.toJson();
      });
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e, st) {
      developer.log(
        'KnowledgePointProgressRepository save failed',
        name: 'ai_feynman.kp_progress',
        error: e,
        stackTrace: st,
      );
    }
  }

  @visibleForTesting
  void resetCacheOnlyForTesting() {
    _cache.clear();
    _loaded = false;
    _pendingLoad = null;
    _writeQueue = Future<void>.value();
  }
}
