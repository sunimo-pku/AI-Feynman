import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/review_models.dart';
import 'auth_service.dart';
import 'progress_repository.dart';
import 'review_repository.dart';

/// 第十轮：把本地 `SectionProgress` + `LectureReviewRecord` 同步到后端
/// `/learning/progress/sync`，并把服务端返回的「合并后」结果回灌给本地仓库。
///
/// 设计：
///   * 单例 + ChangeNotifier，便于首页 / 家长端订阅「最后一次同步时间」；
///   * 未登录时静默跳过，**不**抛异常（学生端在 demo 模式下仍能正常使用）；
///   * 任意网络异常 / 5xx 都只在 [lastError] 暴露，不打断 UI 流程；
///   * sync 内部串行化：连按两次「立即同步」不会触发竞态；
///   * 不在主线程长期 hold；单次 timeout 12s，超时即标记失败。
class LearningSyncService extends ChangeNotifier {
  LearningSyncService._({http.Client? client})
    : _client = client ?? http.Client();

  static final LearningSyncService instance = LearningSyncService._();

  final http.Client _client;
  DateTime? _lastSyncedAt;
  String? _lastError;
  bool _inFlight = false;
  Future<bool>? _pending;

  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get lastError => _lastError;
  bool get isSyncing => _inFlight;

  @visibleForTesting
  Future<void> applyServerPayloadForTesting(Map<String, dynamic> body) =>
      _applyServerPayload(body);

  /// 立即把本地进度 + 回顾推到后端。返回 true 表示同步成功。
  ///
  /// 多个调用并发时复用同一个 [_pending]，避免重复请求。
  /// 调用方应在「讲题完成」「家长端打开」「下拉刷新」三处调用。
  Future<bool> syncNow() {
    final pending = _pending;
    if (pending != null) return pending;
    final future = _runSync();
    _pending = future;
    future.whenComplete(() => _pending = null);
    return future;
  }

  Future<bool> pullAndMerge() {
    final pending = _pending;
    if (pending != null) return pending;
    final future = _runPull();
    _pending = future;
    future.whenComplete(() => _pending = null);
    return future;
  }

  Future<bool> postReview(LectureReviewRecord record) async {
    final auth = AuthService.instance;
    if (!auth.isLoggedIn) return false;
    try {
      final resp = await _client
          .post(
            ApiConfig.uri('/learning/reviews'),
            headers: auth.authHeaders(),
            body: utf8.encode(
              jsonEncode({
                'id': record.id,
                'sectionId': record.sectionId,
                'questionId': record.questionId,
                'questionPrompt': record.questionPrompt,
                'difficulty': record.difficulty,
                'tags': record.tags,
                'completedAt': record.completedAt.toIso8601String(),
                'summary': record.summary,
                'agentHighlights': record.agentHighlights,
                'cautionPoints': record.cautionPoints,
              }),
            ),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e, st) {
      developer.log(
        'LearningSyncService postReview failed',
        name: 'ai_feynman.sync',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<bool> _runSync() async {
    final auth = AuthService.instance;
    if (!auth.isLoggedIn) {
      _lastError = '未登录，跳过同步。';
      notifyListeners();
      return false;
    }
    _inFlight = true;
    notifyListeners();
    try {
      // 等本地仓库 load 完成，避免上传空 payload 把服务端覆盖。
      await ProgressRepository.instance.load();
      await ReviewRepository.instance.load();

      final progressItems = _collectLocalProgress();
      final reviewItems = _collectLocalReviews();

      final body = jsonEncode({
        'mode': 'merge',
        'progress': progressItems,
        'reviews': reviewItems,
      });
      final resp = await _client
          .post(
            ApiConfig.uri('/learning/progress/sync'),
            headers: auth.authHeaders(),
            body: utf8.encode(body),
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode == 401) {
        _lastError = '登录态已过期，请重新登录。';
        return false;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _lastError = '同步失败（HTTP ${resp.statusCode}）。';
        return false;
      }

      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        _lastError = '后端返回格式异常。';
        return false;
      }
      await _applyServerPayload(decoded);
      _lastSyncedAt = DateTime.now();
      _lastError = null;
      return true;
    } on TimeoutException {
      _lastError = '同步超时，请稍后重试。';
      return false;
    } on SocketException {
      _lastError = '连不上后端（${ApiConfig.baseUrl}）。';
      return false;
    } catch (e, st) {
      developer.log(
        'LearningSyncService sync failed',
        name: 'ai_feynman.sync',
        error: e,
        stackTrace: st,
      );
      _lastError = '同步异常：$e';
      return false;
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  Future<bool> _runPull() async {
    final auth = AuthService.instance;
    if (!auth.isLoggedIn) return false;
    _inFlight = true;
    notifyListeners();
    try {
      final progressResp = await _client
          .get(ApiConfig.uri('/learning/progress'), headers: auth.authHeaders())
          .timeout(const Duration(seconds: 12));
      final reviewResp = await _client
          .get(ApiConfig.uri('/learning/reviews'), headers: auth.authHeaders())
          .timeout(const Duration(seconds: 12));
      if (progressResp.statusCode >= 200 && progressResp.statusCode < 300) {
        final progress = jsonDecode(utf8.decode(progressResp.bodyBytes));
        await _applyServerPayload({'progress': progress, 'reviews': const []});
      }
      if (reviewResp.statusCode >= 200 && reviewResp.statusCode < 300) {
        final reviews = jsonDecode(utf8.decode(reviewResp.bodyBytes));
        await _applyServerPayload({'progress': const [], 'reviews': reviews});
      }
      _lastSyncedAt = DateTime.now();
      _lastError = null;
      return true;
    } catch (e, st) {
      developer.log(
        'LearningSyncService pull failed',
        name: 'ai_feynman.sync',
        error: e,
        stackTrace: st,
      );
      _lastError = '拉取同步失败：$e';
      return false;
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _collectLocalProgress() {
    final repo = ProgressRepository.instance;
    final out = <Map<String, dynamic>>[];
    for (final p in repo.allProgress) {
      if (!p.hasAnyCompletion) continue;
      out.add({
        'sectionId': p.sectionId,
        'completedRounds': p.completedRounds,
        'masteryScore': p.masteryScore,
        'lastPracticedAt': p.lastPracticedAt?.toIso8601String(),
        'lastSummary': p.lastSummary,
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _collectLocalReviews() {
    final repo = ReviewRepository.instance;
    return repo.allRecords
        .map(
          (r) => {
            'id': r.id,
            'sectionId': r.sectionId,
            'questionId': r.questionId,
            'questionPrompt': r.questionPrompt,
            'difficulty': r.difficulty,
            'tags': r.tags,
            'completedAt': r.completedAt.toIso8601String(),
            'summary': r.summary,
            'agentHighlights': r.agentHighlights,
            'cautionPoints': r.cautionPoints,
          },
        )
        .toList(growable: false);
  }

  /// 把服务端「合并后」的 progress / review 灌回本地仓库。
  ///
  /// 仅对 server 比 local 更高的字段做覆盖；本地暂未实现「整张表替换」，
  /// 因为 V1 数据量极小（最多 3 个 section + 30 条 review），多写一次
  /// shared_preferences 是可以接受的。
  Future<void> _applyServerPayload(Map<String, dynamic> body) async {
    final serverProgress = body['progress'];
    if (serverProgress is List) {
      final progressRepo = ProgressRepository.instance;
      for (final item in serverProgress) {
        if (item is! Map<String, dynamic>) continue;
        final serverScore = (item['masteryScore'] as num?)?.toInt() ?? 0;
        final serverRounds = (item['completedRounds'] as num?)?.toInt() ?? 0;
        final sectionId = item['sectionId'] as String? ?? '';
        if (sectionId.isEmpty) continue;
        final local = progressRepo.progressFor(sectionId);
        final serverPracticedAt = DateTime.tryParse(
          item['lastPracticedAt'] as String? ?? '',
        );
        final serverSummary = item['lastSummary'] as String? ?? '';
        final serverIsNewer = (serverPracticedAt ??
                DateTime.fromMillisecondsSinceEpoch(0))
            .isAfter(
              local.lastPracticedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            );
        final summaryChanged =
            serverSummary.isNotEmpty && serverSummary != local.lastSummary;
        if (serverScore <= local.masteryScore &&
            serverRounds <= local.completedRounds &&
            !serverIsNewer &&
            !summaryChanged) {
          continue;
        }
        await progressRepo.applyFromServer(
          local.copyWith(
            completedRounds:
                serverRounds > local.completedRounds
                    ? serverRounds
                    : local.completedRounds,
            masteryScore:
                serverScore > local.masteryScore
                    ? serverScore
                    : local.masteryScore,
            lastSummary:
                serverSummary.isNotEmpty ? serverSummary : local.lastSummary,
            lastPracticedAt:
                serverIsNewer ? serverPracticedAt : local.lastPracticedAt,
          ),
        );
      }
    }

    final serverReviews = body['reviews'];
    if (serverReviews is List) {
      final reviewRepo = ReviewRepository.instance;
      final existingIds = reviewRepo.allRecords.map((r) => r.id).toSet();
      for (final item in serverReviews) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id'] as String? ?? '';
        if (id.isEmpty || existingIds.contains(id)) continue;
        final record = LectureReviewRecord.fromJson({
          ...item,
          'completedAt': item['completedAt'],
        });
        if (record.id.isNotEmpty) {
          await reviewRepo.append(record);
        }
      }
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
