import 'dart:convert';

import 'package:flutter/services.dart';

import 'lecture_models.dart';

/// 本地题库 Mock：第七轮起每个 V1 可练习章节内置 3 道题。
///
/// 设计要点：
///
/// - 第十二轮起优先加载 asset JSON；内嵌 16 章题作为冷启动兜底；
/// - 每道题在原有 `questionId / sectionId / sectionLabel / prompt / hint /
///   referenceSteps` 基础上轻量加厚 `difficulty`（1=基础 / 2=巩固 / 3=挑战）
///   与 `tags`（1-3 个知识标签），仅供讲题页 chip 展示；
/// - 难度数字**不**直接进入 UI，统一经 [difficultyLabel] 翻译成中文；
/// - 后端契约不变：`/lecture/submit` 仍只用 `questionId` + `questionPrompt`，
///   `tags` / `difficulty` 不上送。
///
/// 第二轮起，多 Agent 追问（`turns`）改由后端 `POST /lecture/submit` 返回，
/// 本仓库不再生成 [LectureDiscussion] 之类的对话 Mock。
class MockLectureRepository {
  MockLectureRepository._();
  static final MockLectureRepository instance = MockLectureRepository._();

  static const questionBankAssetPath =
      'assets/questions/pep-junior-math-questions.json';

  final Map<String, List<LectureQuestion>> _assetBank =
      <String, List<LectureQuestion>>{};
  bool _assetLoaded = false;

  Future<void> loadAssetBank() async {
    if (_assetLoaded) return;
    final raw = await rootBundle.loadString(questionBankAssetPath);
    final decoded = jsonDecode(raw);
    final list = decoded is Map<String, dynamic> ? decoded['questions'] : null;
    if (list is! List) {
      _assetLoaded = true;
      return;
    }
    final next = <String, List<LectureQuestion>>{};
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final q = LectureQuestion.fromJson(item);
      if (q.questionId.isEmpty || q.sectionId.isEmpty) continue;
      next.putIfAbsent(q.sectionId, () => <LectureQuestion>[]).add(q);
    }
    _assetBank
      ..clear()
      ..addAll(next.map((key, value) => MapEntry(key, List.unmodifiable(value))));
    _assetLoaded = true;
  }

  /// 资产题库加载失败或未知 section 时只走通用模板题。
  ///
  /// 这里不能再内嵌任何具体章节题目；真实题目统一来自全册 JSON asset。
  static final Map<String, List<LectureQuestion>> _bank = {};

  /// 取一个章节下的全部题目；未知 `sectionId` 只生成该章节自己的通用模板题，
  /// 禁止回退到某个具体章节，避免把固定章节题目串到其他章节。
  ///
  /// 返回值是不可变视图，调用方不要尝试 mutate。
  List<LectureQuestion> questionsForSection(String sectionId) {
    final list =
        _assetBank[sectionId] ?? _bank[sectionId] ?? [_stubQuestionForSection(sectionId)];
    return List.unmodifiable(list);
  }

  /// 取一个章节下的指定题目。约束：
  ///
  /// - 旧调用 `questionForSection(sectionId)` 仍可工作，等价于 `index = 0`，
  ///   返回该节第 1 题，保持第六轮以前的接口语义不被破坏。
  /// - `index` 可以传任意整数；当超出范围（含负数）时按 `index % count`
  ///   做 modulo 循环（Dart 的 `%` 对负数返回非负余数），**不**抛异常。
  /// - 未知 `sectionId` 返回该章节自己的通用模板题，不串用任何具体章节。
  LectureQuestion questionForSection(String sectionId, {int index = 0}) {
    final list =
        _assetBank[sectionId] ?? _bank[sectionId] ?? [_stubQuestionForSection(sectionId)];
    if (list.isEmpty) {
      // 题库被误清空时仍给当前章节一题通用模板，不回退到固定章节。
      return _stubQuestionForSection(sectionId);
    }
    final safeIndex = index % list.length;
    return list[safeIndex];
  }

  /// 章节内题量，供首页「3 道题 · 可练习」徽标和讲题页「第 N / M 题」展示。
  ///
  /// 未知章节返回 0：首页据此**不**展示题量徽标，避免对未上线章节误标。
  int questionCountForSection(String sectionId) {
    final list = _assetBank[sectionId] ?? _bank[sectionId];
    return list?.length ?? 1;
  }

  /// 把开发字段 `difficulty` 翻译成 UI 用的中文标签：
  ///   * `1` → `基础`
  ///   * `2` → `巩固`
  ///   * `3` → `挑战`
  String difficultyLabel(int difficulty) {
    switch (difficulty) {
      case 3:
        return '挑战';
      case 2:
        return '巩固';
      case 1:
      default:
        return '基础';
    }
  }

  /// 本题配置的相关变式题；缺省时回退到同节下一题（循环）。
  LectureQuestion variantFor(LectureQuestion current) {
    final list = questionsForSection(current.sectionId);
    if (list.isEmpty) return current;
    if (current.variantQuestionId.isNotEmpty) {
      for (final q in list) {
        if (q.questionId == current.variantQuestionId) return q;
      }
    }
    final idx = list.indexWhere((q) => q.questionId == current.questionId);
    final next = idx >= 0 ? (idx + 1) % list.length : 0;
    return list[next];
  }

  LectureQuestion _stubQuestionForSection(String sectionId) {
    return LectureQuestion(
      questionId: 'q-$sectionId-stub-001',
      sectionId: sectionId,
      sectionLabel: '教研中小节',
      prompt: '教研中模板题：请结合本节标题，讲清一个核心概念、一个例题步骤和一个容易出错的地方。',
      hint: '提示：先说定义，再写一步例题，最后总结易错点。',
      referenceSteps: const [
        '写出本节核心概念',
        '列出一个代表性步骤',
        '总结易错点',
      ],
      difficulty: 1,
      tags: const ['教研中', '全册题库'],
      standardAnswer: '（教研占位）本题标准答案与完整步骤将于后续版本填入。',
      variantQuestionId: 'q-$sectionId-stub-001',
    );
  }
}
