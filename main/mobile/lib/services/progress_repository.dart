import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/progress_models.dart';

/// 第六轮：本地学习进度仓库。
///
/// 责任：
///   * 在 App 启动后异步从 `shared_preferences` 读出 `sectionId -> SectionProgress`
///     的 JSON map（一次 I/O，结果常驻 [_cache]）。
///   * 提供 [progressFor]（同步快照）、[load]（异步预热）、[applyCompleted]
///     （写回并 notify）三个供 UI 使用的入口。
///   * 自身是 [ChangeNotifier]：首页订阅它即可在讲题页落库后自动刷新
///     本节小节的「已完成 N 轮 · 掌握度 X/100」，不需要写 callback 链。
///
/// 设计取舍：
///   * 单例（[instance]）：进度本质是 App 全局共享一份的；引入 provider /
///     riverpod 会违反「不引入重型状态管理框架」的边界。
///   * 容错：任何阶段读 / 写失败，都**只**在 `developer.log` 打 warning,
///     不抛异常 —— brief 第 8 节明确要求「不要因为 progress 读取失败影响
///     课程目录展示。失败时可以当作空进度」。
///   * 防重复加分：每次 [applyCompleted] 内部串行化 `_save` 写盘，避免并发
///     提交（学生 30s 内连点两次「下一题」）导致先后两次写盘相互覆盖。
///
/// 存储格式：
/// ```json
/// {
///   "pep-g8-down-s16-1": {"sectionId":"...", "completedRounds":1, ...},
///   "pep-g8-down-s16-3": {"sectionId":"...", "completedRounds":2, ...}
/// }
/// ```
/// 整张 map 序列化进同一个 key [_storageKey]，方便整体覆盖写。
class ProgressRepository extends ChangeNotifier {
  ProgressRepository._();

  static final ProgressRepository instance = ProgressRepository._();

  /// `shared_preferences` 里持久化的 key。改格式时必须改这个 key（如 `.v2`）,
  /// 否则老用户读出的字段语义会漂移。
  static const String _storageKey = 'ai_feynman.section_progress.v1';

  final Map<String, SectionProgress> _cache = <String, SectionProgress>{};

  /// 是否已经完成首屏 load。第二次 [load] 直接返回缓存，避免每次首页
  /// pushReplacement 都重读一次 `shared_preferences`。
  bool _loaded = false;
  Future<void>? _pendingLoad;

  /// 写盘锁：避免并发 [applyCompleted] 引发「读旧 → 各写各 → 互相覆盖」。
  Future<void> _writeQueue = Future<void>.value();

  /// 用例：测试场景下注入一个内存版的 `SharedPreferences`。
  ///
  /// 生产代码不要碰这个字段，让 [_obtainPrefs] 自己 `getInstance`。
  @visibleForTesting
  SharedPreferences? testPrefsOverride;

  Future<SharedPreferences> _obtainPrefs() async {
    if (testPrefsOverride != null) return testPrefsOverride!;
    return SharedPreferences.getInstance();
  }

  /// 异步预热缓存。多次调用复用同一个 future，且失败时把内部 future 重置，
  /// 让调用方可以「失败后下一次重试」。
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
            if (value is Map<String, dynamic>) {
              final progress = SectionProgress.fromJson(value);
              if (progress.sectionId.isNotEmpty) {
                _cache[progress.sectionId] = progress;
              }
            } else if (value is Map) {
              final progress = SectionProgress.fromJson(
                value.cast<String, dynamic>(),
              );
              if (progress.sectionId.isNotEmpty) {
                _cache[progress.sectionId] = progress;
              }
            }
          });
        }
      }
      _loaded = true;
    } catch (e, st) {
      developer.log(
        'ProgressRepository load failed; treating as empty',
        name: 'ai_feynman.progress',
        error: e,
        stackTrace: st,
      );
      _cache.clear();
      _loaded = true; // 故意标记 loaded：失败 = 空进度，UI 不要无限 spinner
    } finally {
      _pendingLoad = null;
      notifyListeners();
    }
  }

  /// 同步返回某小节的本地进度快照。
  ///
  /// 调用方应在 build 阶段使用：若仓库尚未 load 完成，返回 [SectionProgress.empty]。
  /// load 完成后会 [notifyListeners]，UI 自动重建拿到真正数据。
  SectionProgress progressFor(String sectionId) {
    return _cache[sectionId] ?? SectionProgress.empty(sectionId);
  }

  /// 是否已经有过任意一条本地进度（用于首页徽标提示）。
  bool get isLoaded => _loaded;

  /// 应用一次「老师说 completed」：算出新的 SectionProgress、写盘、通知 UI。
  ///
  /// 返回 `(next, gained)`：UI 拿 `gained` 直接显示「本节掌握度 +X」。
  ///
  /// 注意：调用方必须保证此刻**确实**是后端返回了 `status: "completed"`,
  /// 仓库不再做二次判断；同一道题学生连点两次「下一题」也只算一次（前端
  /// 状态机已经在收到 completed 后切到 finished，不会再次发请求）。
  Future<({SectionProgress next, int gained})> applyCompleted({
    required String sectionId,
    required int masteryDelta,
    required String summary,
    DateTime? when,
  }) async {
    // 串行化写盘，防止并发 applyCompleted 互相覆盖。
    final completer = Completer<({SectionProgress next, int gained})>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        if (!_loaded) {
          await _loadInternal();
        }
        final current = _cache[sectionId] ?? SectionProgress.empty(sectionId);
        final result = current.applyCompleted(
          masteryDelta: masteryDelta,
          summary: summary,
          when: when ?? DateTime.now(),
        );
        _cache[sectionId] = result.next;
        await _save();
        notifyListeners();
        completer.complete(result);
      } catch (e, st) {
        developer.log(
          'ProgressRepository applyCompleted failed: section=$sectionId',
          name: 'ai_feynman.progress',
          error: e,
          stackTrace: st,
        );
        // 失败时返回一个「未变化」的快照，避免 UI 拿 null 崩。
        final fallback = _cache[sectionId] ?? SectionProgress.empty(sectionId);
        completer.complete((next: fallback, gained: 0));
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
        'ProgressRepository save failed; in-memory cache kept',
        name: 'ai_feynman.progress',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// 仅供测试 / Demo 用：清空本地所有进度。生产 UI 不要暴露此入口，
  /// 学习进度被一键抹掉会严重打击学生体感。
  @visibleForTesting
  Future<void> resetForTesting() async {
    _cache.clear();
    _loaded = true;
    try {
      final prefs = await _obtainPrefs();
      await prefs.remove(_storageKey);
    } catch (_) {
      // 测试场景下忽略写错误。
    }
    notifyListeners();
  }

  /// 仅供测试：只清掉内存缓存与 `_loaded` 标记，**保留** `shared_preferences`
  /// 里持久化的数据。用于模拟「App 重启」—— 下一次 [load] 应当能读出
  /// 之前已经落盘的进度。
  @visibleForTesting
  void resetCacheOnlyForTesting() {
    _cache.clear();
    _loaded = false;
    _pendingLoad = null;
  }
}
