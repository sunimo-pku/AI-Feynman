import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../data/question_engagement_models.dart';
import 'auth_service.dart';

/// 题目收藏：本地缓存 + 登录后与服务端同步。
class FavoriteRepository extends ChangeNotifier {
  FavoriteRepository._();

  static final FavoriteRepository instance = FavoriteRepository._();

  static const String _storagePrefix = 'ai_feynman.question_favorites.v1';
  String _namespace = 'guest';
  String get _storageKey => '$_storagePrefix.$_namespace';

  final Set<String> _favoriteQuestionIds = <String>{};
  final Map<String, QuestionFavoriteItem> _byQuestionId =
      <String, QuestionFavoriteItem>{};
  bool _loaded = false;
  Future<void>? _pendingLoad;
  Future<void> _writeQueue = Future<void>.value();

  @visibleForTesting
  SharedPreferences? testPrefsOverride;

  Future<SharedPreferences> _obtainPrefs() async {
    if (testPrefsOverride != null) return testPrefsOverride!;
    return SharedPreferences.getInstance();
  }

  bool isFavorite(String questionId) => _favoriteQuestionIds.contains(questionId);

  List<QuestionFavoriteItem> get favorites {
    final items = _byQuestionId.values.toList(growable: false);
    items.sort((a, b) {
      final ta = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });
    return items;
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
      _favoriteQuestionIds.clear();
      _byQuestionId.clear();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map<String, dynamic>) continue;
            final fav = QuestionFavoriteItem.fromJson(item);
            if (fav.questionId.isEmpty) continue;
            _favoriteQuestionIds.add(fav.questionId);
            _byQuestionId[fav.questionId] = fav;
          }
        }
      }
      if (AuthService.instance.isLoggedIn && AuthService.instance.isStudent) {
        await _pullFromServer();
      }
    } catch (e, st) {
      developer.log(
        'FavoriteRepository load failed',
        name: 'ai_feynman.favorites',
        error: e,
        stackTrace: st,
      );
    } finally {
      _loaded = true;
      _pendingLoad = null;
      notifyListeners();
    }
  }

  Future<void> switchUser(String namespace) async {
    final next = namespace.trim().isEmpty ? 'guest' : namespace.trim();
    if (next == _namespace && _loaded) return;
    _namespace = next;
    _loaded = false;
    _pendingLoad = null;
    _favoriteQuestionIds.clear();
    _byQuestionId.clear();
    await load();
  }

  Future<void> toggleFavorite({
    required String questionId,
    required String sectionId,
    required String questionPrompt,
    int difficulty = 1,
  }) async {
    await load();
    final next = !isFavorite(questionId);
    if (next) {
      final item = QuestionFavoriteItem(
        questionId: questionId,
        sectionId: sectionId,
        questionPrompt: questionPrompt,
        difficulty: difficulty,
        createdAt: DateTime.now(),
      );
      _favoriteQuestionIds.add(questionId);
      _byQuestionId[questionId] = item;
    } else {
      _favoriteQuestionIds.remove(questionId);
      _byQuestionId.remove(questionId);
    }
    notifyListeners();
    _writeQueue = _writeQueue.then((_) async {
      await _persistLocal();
      if (!AuthService.instance.isLoggedIn || !AuthService.instance.isStudent) {
        return;
      }
      try {
        if (next) {
          await _putFavorite(
            questionId: questionId,
            sectionId: sectionId,
            questionPrompt: questionPrompt,
            difficulty: difficulty,
          );
        } else {
          await _deleteFavorite(questionId);
        }
      } catch (e, st) {
        developer.log(
          'Favorite sync failed',
          name: 'ai_feynman.favorites',
          error: e,
          stackTrace: st,
        );
      }
    });
    await _writeQueue;
  }

  Future<void> _persistLocal() async {
    try {
      final prefs = await _obtainPrefs();
      final payload = favorites.map((e) => e.toJson()).toList(growable: false);
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e, st) {
      developer.log(
        'Favorite persist failed',
        name: 'ai_feynman.favorites',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _pullFromServer() async {
    final uri = ApiConfig.uri('/learning/favorites');
    final resp = await http
        .get(uri, headers: AuthService.instance.authHeaders())
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return;
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (body is! Map<String, dynamic>) return;
    final raw = body['favorites'];
    if (raw is! List) return;
    _favoriteQuestionIds.clear();
    _byQuestionId.clear();
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final fav = QuestionFavoriteItem.fromJson(item);
      if (fav.questionId.isEmpty) continue;
      _favoriteQuestionIds.add(fav.questionId);
      _byQuestionId[fav.questionId] = fav;
    }
    await _persistLocal();
  }

  Future<void> _putFavorite({
    required String questionId,
    required String sectionId,
    required String questionPrompt,
    required int difficulty,
  }) async {
    final uri = ApiConfig.uri('/learning/favorites');
    final resp = await http
        .put(
          uri,
          headers: {
            ...AuthService.instance.authHeaders(),
            'Content-Type': 'application/json',
          },
          body: utf8.encode(jsonEncode({
            'questionId': questionId,
            'sectionId': sectionId,
            'questionPrompt': questionPrompt,
            'difficulty': difficulty,
            'favorited': true,
          })),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('favorite put ${resp.statusCode}');
    }
  }

  Future<void> _deleteFavorite(String questionId) async {
    final uri = ApiConfig.uri('/learning/favorites/$questionId');
    final resp = await http
        .delete(uri, headers: AuthService.instance.authHeaders())
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw HttpException('favorite delete ${resp.statusCode}');
    }
  }

  @visibleForTesting
  void resetCacheOnlyForTesting() {
    _loaded = false;
    _pendingLoad = null;
    _favoriteQuestionIds.clear();
    _byQuestionId.clear();
  }
}

/// 向家长反馈题目（仅服务端，失败抛异常由 UI 提示）。
class QuestionEngagementService {
  QuestionEngagementService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _client;
  final Duration _timeout;

  Future<void> submitQuestionFeedback({
    required String questionId,
    required String sectionId,
    required String questionPrompt,
    required String note,
    int difficulty = 1,
  }) async {
    if (!AuthService.instance.isLoggedIn || !AuthService.instance.isStudent) {
      throw StateError('需要登录学生账号才能反馈给家长');
    }
    final uri = ApiConfig.uri('/learning/question-feedback');
    final resp = await _client
        .post(
          uri,
          headers: {
            ...AuthService.instance.authHeaders(),
            'Content-Type': 'application/json',
          },
          body: utf8.encode(jsonEncode({
            'questionId': questionId,
            'sectionId': sectionId,
            'questionPrompt': questionPrompt,
            'note': note.trim(),
            'difficulty': difficulty,
          })),
        )
        .timeout(_timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('question-feedback ${resp.statusCode}');
    }
  }

  void close() => _client.close();
}
