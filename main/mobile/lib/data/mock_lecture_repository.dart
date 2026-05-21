import 'dart:math';

import 'lecture_models.dart';

/// V1 阶段的本地 Mock：根据章节 ID 返回固定题目；提交后返回固定多 Agent 追问。
///
/// 后续接入后端时只需替换实现，保留方法签名（返回 Future）。
class MockLectureRepository {
  MockLectureRepository._();
  static final MockLectureRepository instance = MockLectureRepository._();

  static const _defaultSection = 'pep-g8-down-s16-1';

  static final Map<String, LectureQuestion> _questions = {
    'pep-g8-down-s16-1': const LectureQuestion(
      questionId: 'mock-radical-001',
      sectionId: 'pep-g8-down-s16-1',
      sectionLabel: '16.1 二次根式',
      prompt: r'判断 $\sqrt{2x-6}$ 在实数范围内有意义时，$x$ 的取值范围。',
      hint: '提示：被开方数必须非负。',
      referenceSteps: [
        r'$2x - 6 \ge 0$',
        r'$x \ge 3$',
      ],
    ),
    'pep-g8-down-s16-2': const LectureQuestion(
      questionId: 'mock-radical-002',
      sectionId: 'pep-g8-down-s16-2',
      sectionLabel: '16.2 二次根式的乘除',
      prompt: r'化简：$\sqrt{12} \cdot \sqrt{3}$，并说明用到的乘法法则。',
      hint: r'提示：$\sqrt{a} \cdot \sqrt{b} = \sqrt{ab}$（$a, b \ge 0$）。',
      referenceSteps: [
        r'$\sqrt{12 \cdot 3}$',
        r'$\sqrt{36}$',
        r'$= 6$',
      ],
    ),
    'pep-g8-down-s16-3': const LectureQuestion(
      questionId: 'mock-radical-003',
      sectionId: 'pep-g8-down-s16-3',
      sectionLabel: '16.3 二次根式的加减',
      prompt: r'化简：$\sqrt{12} - \sqrt{27}$。',
      hint: '提示：先化为最简二次根式，再合并同类二次根式。',
      referenceSteps: [
        r'$\sqrt{12} = 2\sqrt{3}$',
        r'$\sqrt{27} = 3\sqrt{3}$',
        r'$2\sqrt{3} - 3\sqrt{3} = -\sqrt{3}$',
      ],
    ),
  };

  LectureQuestion questionForSection(String sectionId) {
    return _questions[sectionId] ?? _questions[_defaultSection]!;
  }

  /// 模拟一次「提交讲解 → 多 Agent 追问」。
  ///
  /// [stepIds] 由 [HandCanvas] 提交时传入，用于让 Mock 数据中
  /// `highlightStepIds` 命中真实存在的步骤，从而触发画布高亮效果。
  Future<LectureDiscussion> submitExplanation({
    required String sectionId,
    required List<String> stepIds,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final question = questionForSection(sectionId);
    final rng = Random(question.questionId.hashCode ^ stepIds.length);

    final firstStep = stepIds.isNotEmpty ? stepIds.first : 'step_1';
    final lastStep = stepIds.isNotEmpty ? stepIds.last : firstStep;
    final midStep = stepIds.length >= 2 ? stepIds[stepIds.length ~/ 2] : firstStep;

    final turns = _turnsFor(
      sectionId: sectionId,
      firstStep: firstStep,
      midStep: midStep,
      lastStep: lastStep,
      seed: rng,
    );

    return LectureDiscussion(
      questionId: question.questionId,
      turns: turns,
      summary: '已记录本轮讲解。继续往下讲，或者点击「我懂了/下一题」结束这一轮。',
    );
  }

  List<AgentTurn> _turnsFor({
    required String sectionId,
    required String firstStep,
    required String midStep,
    required String lastStep,
    required Random seed,
  }) {
    switch (sectionId) {
      case 'pep-g8-down-s16-1':
        return [
          AgentTurn(
            role: AgentRole.xiaoming,
            displayName: '小明',
            text: '等等，被开方数是 2x-6，你怎么知道一定要让它 ≥ 0 呀？是不是因为负数开根号在实数范围里没意义？',
            highlightStepIds: [firstStep],
          ),
          AgentTurn(
            role: AgentRole.teacher,
            displayName: '李老师',
            text: r'问得不错。你能不能再补一句：写完不等式 $2x-6 \ge 0$ 之后，怎么推出 $x \ge 3$？',
            highlightStepIds: [lastStep],
          ),
        ];
      case 'pep-g8-down-s16-2':
        return [
          AgentTurn(
            role: AgentRole.xiaoming,
            displayName: '小明',
            text: r'你直接把 $\sqrt{12} \cdot \sqrt{3}$ 写成 $\sqrt{36}$，这里用了一条法则吧？前提是什么呀？',
            highlightStepIds: [firstStep],
          ),
          AgentTurn(
            role: AgentRole.teacher,
            displayName: '李老师',
            text: r'对的，要强调 $a \ge 0$、$b \ge 0$ 才能这样合并。你能把这句条件补到你刚才那一步旁边吗？',
            highlightStepIds: [midStep],
          ),
        ];
      case 'pep-g8-down-s16-3':
      default:
        return [
          AgentTurn(
            role: AgentRole.xiaoming,
            displayName: '小明',
            text: r'我有点疑惑，$\sqrt{12}$ 为什么可以变成 $2\sqrt{3}$？这里用了什么规律？',
            highlightStepIds: [firstStep],
          ),
          AgentTurn(
            role: AgentRole.teacher,
            displayName: '李老师',
            text: r'这个问题问得很好。你可以试着把 12 拆成 $4 \times 3$，再说明为什么 4 能从根号里出来。同样地，$\sqrt{27}$ 也试一下。',
            highlightStepIds: [midStep],
          ),
        ];
    }
  }
}
