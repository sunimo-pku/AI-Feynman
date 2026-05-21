import 'lecture_models.dart';

/// 本地题库 Mock：第七轮起每个 V1 可练习章节内置 3 道题。
///
/// 设计要点：
///
/// - 仅前端 Dart 内嵌，**不**引入 JSON 题库文件，保持本轮轻量；
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

  static const _defaultSection = 'pep-g8-down-s16-1';

  /// 每个 sectionId 对应的题目列表，顺序即"第 1 / 3 题、第 2 / 3 题…"。
  ///
  /// 同一章节内的题目按"基础 → 巩固 → 挑战"排列，方便学生从易到难切入；
  /// `index` 超出长度时由 [questionForSection] 做 modulo 循环，不抛异常。
  static final Map<String, List<LectureQuestion>> _bank = {
    'pep-g8-down-s16-1': const [
      LectureQuestion(
        questionId: 'q-s16-1-001',
        sectionId: 'pep-g8-down-s16-1',
        sectionLabel: '16.1 二次根式',
        prompt: r'判断 $\sqrt{2x-6}$ 在实数范围内有意义时，$x$ 的取值范围。',
        hint: '提示：被开方数必须非负。',
        referenceSteps: [
          r'$2x - 6 \ge 0$',
          r'$x \ge 3$',
        ],
        difficulty: 1,
        tags: ['取值范围', '非负条件'],
      ),
      LectureQuestion(
        questionId: 'q-s16-1-002',
        sectionId: 'pep-g8-down-s16-1',
        sectionLabel: '16.1 二次根式',
        prompt: r'判断 $\sqrt{5-x}$ 在实数范围内有意义时，$x$ 的取值范围。',
        hint: r'提示：把不等式 $5 - x \ge 0$ 化简后再写结论。',
        referenceSteps: [
          r'$5 - x \ge 0$',
          r'$x \le 5$',
        ],
        difficulty: 2,
        tags: ['取值范围', '移项'],
      ),
      LectureQuestion(
        questionId: 'q-s16-1-003',
        sectionId: 'pep-g8-down-s16-1',
        sectionLabel: '16.1 二次根式',
        prompt: r'判断 $\sqrt{x+3} + \sqrt{2-x}$ 在实数范围内有意义时，$x$ 的取值范围。',
        hint: r'提示：两个被开方数都要 $\ge 0$，最终取交集。',
        referenceSteps: [
          r'$x + 3 \ge 0 \Rightarrow x \ge -3$',
          r'$2 - x \ge 0 \Rightarrow x \le 2$',
          r'$-3 \le x \le 2$',
        ],
        difficulty: 3,
        tags: ['公共定义域', '不等式组'],
      ),
    ],
    'pep-g8-down-s16-2': const [
      LectureQuestion(
        questionId: 'q-s16-2-001',
        sectionId: 'pep-g8-down-s16-2',
        sectionLabel: '16.2 二次根式的乘除',
        prompt: r'化简：$\sqrt{12} \cdot \sqrt{3}$，并说明用到的乘法法则与前提条件。',
        hint: r'提示：$\sqrt{a} \cdot \sqrt{b} = \sqrt{ab}$（$a, b \ge 0$）。',
        referenceSteps: [
          r'$\sqrt{12 \cdot 3}$',
          r'$\sqrt{36}$',
          r'$= 6$',
        ],
        difficulty: 1,
        tags: ['乘法法则', '前提条件'],
      ),
      LectureQuestion(
        questionId: 'q-s16-2-002',
        sectionId: 'pep-g8-down-s16-2',
        sectionLabel: '16.2 二次根式的乘除',
        prompt: r'化简：$\sqrt{50} \div \sqrt{2}$。',
        hint: r'提示：$\dfrac{\sqrt{a}}{\sqrt{b}} = \sqrt{\dfrac{a}{b}}$（$a \ge 0, b > 0$）。',
        referenceSteps: [
          r'$\sqrt{50 \div 2}$',
          r'$\sqrt{25}$',
          r'$= 5$',
        ],
        difficulty: 2,
        tags: ['除法法则', '化简'],
      ),
      LectureQuestion(
        questionId: 'q-s16-2-003',
        sectionId: 'pep-g8-down-s16-2',
        sectionLabel: '16.2 二次根式的乘除',
        prompt: r'化简：$\sqrt{8} \cdot \sqrt{18}$。',
        hint: '提示：先用乘法法则合并，再把完全平方数全部提出来。',
        referenceSteps: [
          r'$\sqrt{8 \cdot 18}$',
          r'$\sqrt{144}$',
          r'$= 12$',
        ],
        difficulty: 3,
        tags: ['乘法', '完全平方数'],
      ),
    ],
    'pep-g8-down-s16-3': const [
      LectureQuestion(
        questionId: 'q-s16-3-001',
        sectionId: 'pep-g8-down-s16-3',
        sectionLabel: '16.3 二次根式的加减',
        prompt: r'化简：$\sqrt{12} - \sqrt{27}$。',
        hint: '提示：先化为最简二次根式，再合并同类二次根式。',
        referenceSteps: [
          r'$\sqrt{12} = 2\sqrt{3}$',
          r'$\sqrt{27} = 3\sqrt{3}$',
          r'$2\sqrt{3} - 3\sqrt{3} = -\sqrt{3}$',
        ],
        difficulty: 1,
        tags: ['最简二次根式', '同类二次根式'],
      ),
      LectureQuestion(
        questionId: 'q-s16-3-002',
        sectionId: 'pep-g8-down-s16-3',
        sectionLabel: '16.3 二次根式的加减',
        prompt: r'化简：$2\sqrt{8} + \sqrt{18}$。',
        hint: r'提示：先把 $\sqrt{8}$、$\sqrt{18}$ 化成同底再合并。',
        referenceSteps: [
          r'$2\sqrt{8} = 4\sqrt{2}$',
          r'$\sqrt{18} = 3\sqrt{2}$',
          r'$4\sqrt{2} + 3\sqrt{2} = 7\sqrt{2}$',
        ],
        difficulty: 2,
        tags: ['化简', '合并同类项'],
      ),
      LectureQuestion(
        questionId: 'q-s16-3-003',
        sectionId: 'pep-g8-down-s16-3',
        sectionLabel: '16.3 二次根式的加减',
        prompt: r'化简：$\sqrt{45} - 2\sqrt{20} + \sqrt{5}$。',
        hint: r'提示：三项都化成同底 $\sqrt{5}$，再依次合并系数，留意负号。',
        referenceSteps: [
          r'$\sqrt{45} = 3\sqrt{5}$',
          r'$2\sqrt{20} = 4\sqrt{5}$',
          r'$3\sqrt{5} - 4\sqrt{5} + \sqrt{5} = 0$',
        ],
        difficulty: 3,
        tags: ['多项合并', '负号'],
      ),
    ],
  };

  /// 取一个章节下的全部题目；未知 `sectionId` 退回 16.1 题库（与
  /// [questionForSection] 的兜底口径保持一致）。
  ///
  /// 返回值是不可变视图，调用方不要尝试 mutate。
  List<LectureQuestion> questionsForSection(String sectionId) {
    final list = _bank[sectionId] ?? _bank[_defaultSection]!;
    return List.unmodifiable(list);
  }

  /// 取一个章节下的指定题目。约束：
  ///
  /// - 旧调用 `questionForSection(sectionId)` 仍可工作，等价于 `index = 0`，
  ///   返回该节第 1 题，保持第六轮以前的接口语义不被破坏。
  /// - `index` 可以传任意整数；当超出范围（含负数）时按 `index % count`
  ///   做 modulo 循环（Dart 的 `%` 对负数返回非负余数），**不**抛异常。
  /// - 未知 `sectionId` 回退到 16.1 第 1 题。
  LectureQuestion questionForSection(String sectionId, {int index = 0}) {
    final list = _bank[sectionId] ?? _bank[_defaultSection]!;
    if (list.isEmpty) {
      // 兜底：题库被误清空时不让上层崩，仍能进入讲题页。
      return _bank[_defaultSection]!.first;
    }
    final safeIndex = index % list.length;
    return list[safeIndex];
  }

  /// 章节内题量，供首页「3 道题 · 可练习」徽标和讲题页「第 N / M 题」展示。
  ///
  /// 未知章节返回 0：首页据此**不**展示题量徽标，避免对未上线章节误标。
  int questionCountForSection(String sectionId) {
    final list = _bank[sectionId];
    return list?.length ?? 0;
  }

  /// 把开发字段 `difficulty` 翻译成 UI 用的中文标签：
  ///   * `1` → `基础`
  ///   * `2` → `巩固`
  ///   * `3` → `挑战`
  ///   * 其他值兜底回「基础」，避免 UI 出现空 chip。
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
}
