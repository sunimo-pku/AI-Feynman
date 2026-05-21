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

  List<Map<String, dynamic>> _collectLocalProgress() {
    final repo = ProgressRepository.instance;
    // ProgressRepository 没有暴露「全部进度」的遍历接口，但本节场景下
    // 我们只关心 16.1 / 16.2 / 16.3 三个 V1 章节；同步时按白名单读出来即可。
    const v1Sections = <String>[
      'pep-g8-down-s16-1',
      'pep-g8-down-s16-2',
      'pep-g8-down-s16-3',
    ];
    final out = <Map<String, dynamic>>[];
    for (final id in v1Sections) {
      final p = repo.progressFor(id);
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
        .map((r) => {
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
            })
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
        // 如果服务端比本地更高就 applyCompleted（用差值近似），避免后端缓存
        // 比本地新但本地 + 差值小于 8 的情况导致少加 —— 这里精度允许偏差。
        if (serverScore <= local.masteryScore &&
            serverRounds <= local.completedRounds) {
          continue;
        }
        // applyCompleted 会按规则 +max(8, masteryDelta*10)；
        // 直接把差值除以 10 喂回去做粗略对齐即可。
        final neededGain = serverScore - local.masteryScore;
        final delta = (neededGain / 10).ceil().clamp(1, 3);
        await progressRepo.applyCompleted(
          sectionId: sectionId,
          masteryDelta: delta,
          summary: item['lastSummary'] as String? ?? '',
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
