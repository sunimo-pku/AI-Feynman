import 'lecture_models.dart';

/// 本地仅保留「题目」Mock：每个 V1 可练习章节固定一道二次根式题。
///
/// 第二轮起，多 Agent 追问（`turns`）改由后端 `POST /lecture/submit` 返回，
/// 本仓库不再生成 [LectureDiscussion] 之类的对话 Mock。
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
}
