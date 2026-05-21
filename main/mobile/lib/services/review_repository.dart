import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/review_models.dart';

/// 第八轮：本地讲题回顾仓库。
///
/// 责任：
///   * 在 App 启动 / 首页进入回顾页时从 `shared_preferences` 异步读出
///     最近若干条 [LectureReviewRecord]，按 `completedAt` 倒序常驻 [_cache]。
///   * 提供 [recordsForSection]（按小节同步快照）、[append]（写入新记录、
///     裁剪到 [_maxRecords] 上限）、[load]（异步预热）三个供 UI 使用的入口。
///   * 自身是 [ChangeNotifier]：回顾页与首页徽标订阅后，写入新记录立即刷新。
///
/// 设计取舍（对齐第六轮 `ProgressRepository`）：
///   * 单例：回顾是 App 全局共享一份的本地缓存，不引入重型状态管理框架。
///   * 容错：任何阶段读 / 写失败，都**只**在 `developer.log` 打 warning，
///     不抛异常 —— brief 第 7 节明确「写入失败只打 log，不影响 completed 体验」。
///   * 串行化写盘：[append] 内部用 `_writeQueue` 把多次写串成链，避免并发
///     提交（理论上不会发生，但写盘异步未完成时连点重置 / 重写仍稳）。
///
/// 存储格式（与 brief 第 7 节示例 1:1 对齐）：
/// ```json
/// [
///   {
///     "id": "q-s16-3-002-1770000000000",
///     "sectionId": "pep-g8-down-s16-3",
///     "questionId": "q-s16-3-002",
///     "questionPrompt": "化简：$2\\sqrt{8} + \\sqrt{18}$。",
///     "difficulty": 2,
///     "tags": ["化简", "合并同类项"],
///     "completedAt": "2026-05-22T00:30:00.000",
///     "summary": "...",
///     "agentHighlights": ["..."],
///     "cautionPoints": ["..."]
///   }
/// ]
/// ```
class ReviewRepository extends ChangeNotifier {
  ReviewRepository._();

  static final ReviewRepository instance = ReviewRepository._();

  /// `shared_preferences` 存储 key。改格式时必须改这个 key（如 `.v2`）,
  /// 否则老用户读出的字段语义会漂移。
  static const String _storageKey = 'ai_feynman.lecture_reviews.v1';

  /// 全局最多保留最近多少条记录。超过则丢弃最旧的，旧记录不会无限增长。
  static const int _maxRecords = 30;

  /// 单小节回顾页只展示该小节最近多少条（按 brief 第 7 节）。
  static const int sectionPageLimit = 10;

  /// 按写入顺序保存（新 -> 旧）。读出时也按倒序排好。
  final List<LectureReviewRecord> _cache = <LectureReviewRecord>[];

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
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final record = LectureReviewRecord.fromJson(item);
              if (record.id.isNotEmpty) {
                _cache.add(record);
              }
            } else if (item is Map) {
              final record = LectureReviewRecord.fromJson(
                item.cast<String, dynamic>(),
              );
              if (record.id.isNotEmpty) {
                _cache.add(record);
              }
            }
          }
        }
      }
      _sortAndTrim();
      _loaded = true;
    } catch (e, st) {
      developer.log(
        'ReviewRepository load failed; treating as empty',
        name: 'ai_feynman.review',
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

  /// 按 `completedAt` 倒序排序，并裁剪到 [_maxRecords] 上限。
  void _sortAndTrim() {
    _cache.sort((a, b) => b.completedAt.compareTo(a.completedAt));
    if (_cache.length > _maxRecords) {
      _cache.removeRange(_maxRecords, _cache.length);
    }
  }

  bool get isLoaded => _loaded;

  /// 全部记录的不可变快照（已按倒序排好）。
  List<LectureReviewRecord> get allRecords =>
      List.unmodifiable(_cache);

  /// 取某小节最近的回顾记录（默认 [sectionPageLimit] 条）。
  ///
  /// 返回值已按 `completedAt` 倒序排好，调用方直接当 ListView 数据源即可。
  /// `limit <= 0` 时返回空列表；调用方传错也不会让 UI 崩。
  List<LectureReviewRecord> recordsForSection(
    String sectionId, {
    int limit = sectionPageLimit,
  }) {
    if (limit <= 0) return const <LectureReviewRecord>[];
    final filtered = _cache
        .where((r) => r.sectionId == sectionId)
        .take(limit)
        .toList(growable: false);
    return List.unmodifiable(filtered);
  }

  /// 某小节是否已经有过本地回顾记录（用于首页「回顾」入口的 enable 与否）。
  bool hasRecordsForSection(String sectionId) {
    for (final r in _cache) {
      if (r.sectionId == sectionId) return true;
    }
    return false;
  }

  /// 写入一条新的回顾记录。串行化、裁剪到上限、通知 UI。
  ///
  /// 失败时不抛异常（已在仓库内部吞掉并打 log）—— 见 brief 第 8 节
  /// 「如果保存 review 失败，掌握度仍应正常更新」。
  Future<void> append(LectureReviewRecord record) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        if (!_loaded) {
          await _loadInternal();
        }
        _cache.insert(0, record);
        _sortAndTrim();
        await _save();
        notifyListeners();
        completer.complete();
      } catch (e, st) {
        developer.log(
          'ReviewRepository append failed: id=${record.id}',
          name: 'ai_feynman.review',
          error: e,
          stackTrace: st,
        );
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _save() async {
    try {
      final prefs = await _obtainPrefs();
      final payload = _cache.map((r) => r.toJson()).toList(growable: false);
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e, st) {
      developer.log(
        'ReviewRepository save failed; in-memory cache kept',
        name: 'ai_feynman.review',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// 仅供测试 / Demo 用：清空本地所有回顾。生产 UI **不**暴露此入口，
  /// 回顾本身是低成本无害数据，没有理由提供「一键擦除」按钮。
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
  /// 之前已经落盘的回顾。
  @visibleForTesting
  void resetCacheOnlyForTesting() {
    _cache.clear();
    _loaded = false;
    _pendingLoad = null;
  }

  /// 第八轮：按题目标签 + summary 文本生成「待注意点」短句。
  ///
  /// 完全本地规则，不调用 LLM。规则集合（见 brief 第 6 节）：
  ///   * `非负条件` / `取值范围` → 「写二次根式前先检查被开方数是否非负」
  ///   * `前提条件` → 「使用乘除法则时要补充 `a, b` 的取值前提」
  ///   * `同类二次根式` / `合并同类项` → 「先化成最简二次根式，再合并同类项系数」
  ///   * `负号` → 「合并系数时留意减号和括号」
  ///   * 都未命中 → 兜底「回看高亮步骤，确认每一步为什么成立」
  ///
  /// 上限 3 条；同一条规则不重复加；保留命中顺序（学生从前到后看更顺）。
  static List<String> derivCautionPoints({
    required List<String> tags,
    String summary = '',
  }) {
    const int maxItems = 3;
    final result = <String>[];

    void add(String item) {
      if (result.length >= maxItems) return;
      if (result.contains(item)) return;
      result.add(item);
    }

    final tagSet = tags.toSet();

    if (tagSet.contains('非负条件') || tagSet.contains('取值范围')) {
      add('写二次根式前先检查被开方数是否非负。');
    }
    if (tagSet.contains('前提条件')) {
      add(r'使用乘除法则时要补充 $a, b$ 的取值前提。');
    }
    if (tagSet.contains('同类二次根式') || tagSet.contains('合并同类项')) {
      add('先化成最简二次根式，再合并同类项系数。');
    }
    if (tagSet.contains('负号')) {
      add('合并系数时留意减号和括号。');
    }

    if (result.isEmpty) {
      add('回看高亮步骤，确认每一步为什么成立。');
    }
    return List.unmodifiable(result);
  }
}
