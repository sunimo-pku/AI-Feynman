import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/lecture_models.dart';
import '../data/mock_lecture_repository.dart';
import '../services/lecture_service.dart';
import '../theme/app_theme.dart';
import '../widgets/agent_message_bubble.dart';
import '../widgets/formula_text.dart';
import '../widgets/hand_canvas.dart';

/// 讲题页：左侧多 Agent 对话区，右侧手写板（横屏），手机竖屏降级为上下布局。
///
/// 第二轮起，提交后通过 [LectureService] 调用后端 `POST /lecture/submit`
/// 拿到多 Agent 追问；失败时画布内容**不清空**，给学生重试机会。
///
/// 第五轮起，本页维护当前题目内的本地多轮对话历史 [_history]：
///
///   * 每次发请求时，把"现存历史 + 本轮学生发言快照"一起放入请求体；
///   * 学生发言快照**只在请求构造时临时拼装**，不立刻 push 到 [_history]，
///     这样失败重试时不会重复追加同一条 `student` 历史；
///   * 仅当请求成功（response.status 任一值）后，才把这条学生发言与
///     后端返回的 `turns` 一起一次性落入 [_history]；
///   * 后端返回 `status: "completed"` 时，进入「这一题讲清楚了」的收束态，
///     不自动清空画布，让学生留时间回看；
///   * 「下一题」会清空 [_history]、画布、口述与每步说明，重新开始。
class LecturePage extends StatefulWidget {
  const LecturePage({
    super.key,
    required this.section,
  });

  final CurriculumSection section;

  @override
  State<LecturePage> createState() => _LecturePageState();
}

enum _LectureStatus { idle, submitting, awaiting, error, finished }

class _LecturePageState extends State<LecturePage> {
  final HandCanvasController _canvasController = HandCanvasController();
  final ScrollController _discussionScrollController = ScrollController();
  final LectureService _lectureService = LectureService();

  /// 学生口述讲解：第四轮新增。
  ///
  /// 该 controller 在 [_onContinue]（「下一题」）时才会被清空，
  /// 提交成功或失败都**不**清空，避免学生为了重试白白重写一遍。
  final TextEditingController _speechController = TextEditingController();

  /// 每个 `stepId` 对应的「中文说明」与「LaTeX 选填」输入控制器。
  ///
  /// 在 [_canvasController] 变化（写新步骤 / 撤销 / 清空）时按需补建或清空：
  ///   * 新出现的 stepId 自动 lazy-create 一对控制器。
  ///   * 画板被 [HandCanvasController.clear] 清空时，所有步骤说明随之清空，
  ///     避免「同一个 step_1 名字下残留上一道题的文字」。
  final Map<String, TextEditingController> _stepPlainControllers =
      <String, TextEditingController>{};
  final Map<String, TextEditingController> _stepLatexControllers =
      <String, TextEditingController>{};

  /// 当前展开了「LaTeX 选填」入口的 stepId 集合；默认不展示，避免初中生被
  /// 看不懂的反斜杠语法吓退。
  final Set<String> _stepLatexExpanded = <String>{};

  late LectureQuestion _question;
  final List<AgentTurn> _turns = <AgentTurn>[];

  /// 本题的多轮对话历史，第五轮新增。仅包含 `student` / AI / `system` 角色的
  /// **结构化历史项**，不包含 UI 用的「正在思考…」呼吸气泡这类临时占位。
  ///
  /// 每次提交时按「最近 6 条」截尾后塞进请求体；后端再做一次清洗与硬上限。
  final List<LectureHistoryItem> _history = <LectureHistoryItem>[];

  _LectureStatus _status = _LectureStatus.idle;
  int _round = 0;
  String? _errorMessage;
  LectureSubmitRequest? _lastFailedRequest;

  /// 后端最近一次返回的 status。`needs_explanation` 默认；`completed` 触发
  /// 「这一题讲清楚了」收束态。第五轮新增。
  String _lastResponseStatus = 'needs_explanation';

  /// 本地历史最多保留多少条。后端也会再做一次硬上限。
  static const int _maxHistoryItems = 6;

  @override
  void initState() {
    super.initState();
    _question = MockLectureRepository.instance.questionForSection(widget.section.id);
    _turns.add(_introTurn());
    _canvasController.addListener(_onCanvasChanged);
  }

  @override
  void dispose() {
    _canvasController.removeListener(_onCanvasChanged);
    _canvasController.dispose();
    _discussionScrollController.dispose();
    _speechController.dispose();
    for (final c in _stepPlainControllers.values) {
      c.dispose();
    }
    for (final c in _stepLatexControllers.values) {
      c.dispose();
    }
    _lectureService.close();
    super.dispose();
  }

  /// 监听手写板变化：
  ///   * 画板被清空（`isEmpty`）时把所有步骤说明输入框文本归零，
  ///     而不是销毁 controller（销毁会让 [TextField] state 报错）。
  ///   * 出现新 stepId 时不在这里建 controller，留给 [_ensureStepControllers]
  ///     在 build 阶段 lazy 创建，避免在 listener 里 setState 抖动。
  void _onCanvasChanged() {
    if (_canvasController.isEmpty) {
      for (final c in _stepPlainControllers.values) {
        if (c.text.isNotEmpty) c.clear();
      }
      for (final c in _stepLatexControllers.values) {
        if (c.text.isNotEmpty) c.clear();
      }
      if (_stepLatexExpanded.isNotEmpty) {
        // 不直接调 setState；canvasController 的 notifyListeners 已经
        // 触发 AnimatedBuilder 重建，这里只清状态即可。
        _stepLatexExpanded.clear();
      }
    }
  }

  /// 为当前画板上的 stepId 集合确保都有对应的输入控制器。
  ///
  /// 在 build 阶段调用，无需 setState。
  void _ensureStepControllers(List<String> stepIds) {
    for (final id in stepIds) {
      _stepPlainControllers.putIfAbsent(id, () => TextEditingController());
      _stepLatexControllers.putIfAbsent(id, () => TextEditingController());
    }
  }

  /// 「最近一条 AI 追问」：从 [_turns] 里找最后一个 role 是
  /// xiaoming/daxiong/monitor/teacher 的气泡。仅用于：
  /// - 切换输入区文案（「回答 XX 的追问」 vs.「我刚才是这样讲的」）
  /// - 在 completed 之后**不再**显示「待回答」提示（此时 status 已 finished，
  ///   输入区在 `awaiting/error` 才暴露给学生，不会出现在收束态）
  AgentTurn? get _pendingAiFollowupTurn {
    if (_status != _LectureStatus.awaiting &&
        _status != _LectureStatus.error) {
      return null;
    }
    for (final t in _turns.reversed) {
      switch (t.role) {
        case AgentRole.xiaoming:
        case AgentRole.daxiong:
        case AgentRole.classLeader:
        case AgentRole.monitor:
        case AgentRole.teacher:
          return t;
        case AgentRole.system:
          continue;
      }
    }
    return null;
  }

  AgentTurn _introTurn() {
    return AgentTurn(
      role: AgentRole.teacher,
      displayName: '李老师',
      text:
          '欢迎来到「${_question.sectionLabel}」讲题课。请你在右侧手写板上写出你的解题步骤，'
          '边写边想；写完后点击「提交讲解」，小明和我会和你一起讨论。',
      highlightStepIds: const [],
    );
  }

  /// 把当前学生输入（口述 + 每步说明）拼装成一条 `student` 历史项。
  ///
  /// 这条文本仅给后端 LLM 看（用于「学生这一轮到底说了什么」），不直接
  /// 在前端气泡展示 —— 前端展示的是手写板原迹 + 现有 system/AI 气泡。
  ///
  /// 故意把每步说明逐条列出来，保留 stepId 关联，方便后端把它和现存的
  /// `steps[*].plainText` 对齐 —— 即使后端日后重写也不会丢语义。
  String _composeStudentHistoryText({
    required String speech,
    required List<HandCanvasStepInfo> stepInfos,
  }) {
    final parts = <String>[];
    if (speech.isNotEmpty) {
      parts.add(speech);
    }
    final stepLines = <String>[];
    for (final info in stepInfos) {
      final plain = _stepPlainControllers[info.stepId]?.text.trim() ?? '';
      if (plain.isEmpty) continue;
      stepLines.add('${info.stepId}：$plain');
    }
    if (stepLines.isNotEmpty) {
      parts.add('（学生分步说明）${stepLines.join('；')}');
    }
    if (parts.isEmpty) {
      return '（学生本轮没有补充任何文字说明）';
    }
    return parts.join(' ');
  }

  /// 把后端返回的一条 [AgentTurn] 转成可上送的 [LectureHistoryItem]，
  /// 用于下一轮请求体里的 history 段。
  LectureHistoryItem _agentTurnToHistory(AgentTurn turn) {
    return LectureHistoryItem(
      role: agentRoleWire(turn.role),
      displayName: turn.displayName,
      text: turn.text,
      highlightStepIds: turn.highlightStepIds,
    );
  }

  /// 取「最近 N 条历史」作为新请求的 history 段。N = [_maxHistoryItems]。
  List<LectureHistoryItem> _historyTail(List<LectureHistoryItem> base) {
    if (base.length <= _maxHistoryItems) return List.unmodifiable(base);
    return List.unmodifiable(
      base.sublist(base.length - _maxHistoryItems),
    );
  }

  LectureSubmitRequest _buildRequest() {
    final stepInfos = _canvasController.collectStepInfos();
    final steps = stepInfos.map((info) {
      final r = info.bounds;
      final plain = _stepPlainControllers[info.stepId]?.text.trim() ?? '';
      final latex = _stepLatexControllers[info.stepId]?.text.trim() ?? '';
      return LectureStepPayload(
        stepId: info.stepId,
        latex: latex,
        plainText: plain,
        strokeCount: info.strokeCount,
        boundingBox: BoundingBoxPayload(
          x: r.left.isFinite ? r.left : 0,
          y: r.top.isFinite ? r.top : 0,
          width: r.width.isFinite && r.width > 0 ? r.width : 1,
          height: r.height.isFinite && r.height > 0 ? r.height : 1,
        ),
      );
    }).toList(growable: false);

    // 第五轮：构造请求时**临时**生成本轮 student 历史项（基于当前输入快照）。
    // 这条记录不立刻 push 进 [_history]；只有请求成功后才会和 AI turns 一起
    // 落库 —— 这样失败重试 [_lastFailedRequest] 时，不会重复追加同一条
    // student 历史，避免学生看到「请求失败 → 历史里多一条自己 → 重试 →
    // 历史又多一条自己」的鬼畜效果。
    final speech = _speechController.text.trim();
    final pendingStudentItem = LectureHistoryItem(
      role: 'student',
      displayName: '我',
      text: _composeStudentHistoryText(
        speech: speech,
        stepInfos: stepInfos,
      ),
      highlightStepIds:
          stepInfos.map((info) => info.stepId).toList(growable: false),
    );

    final historyForRequest = _historyTail(
      [..._history, pendingStudentItem],
    );

    return LectureSubmitRequest(
      sectionId: widget.section.id,
      questionId: _question.questionId,
      questionPrompt: _question.prompt,
      studentSpeechText: speech,
      steps: steps,
      // 提交时是第 (_round + 1) 轮：_round 在请求成功前先不递增，
      // 失败重试也复用同一个 _round + 1 数字，符合「这是第几次提交」的语义。
      roundIndex: _round + 1,
      history: historyForRequest,
    );
  }

  Future<void> _onSubmit() async {
    if (_status == _LectureStatus.submitting) return;
    if (_canvasController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('画板还没有内容，先把你的思路写一两行再提交吧。'),
        ),
      );
      return;
    }
    final request = _buildRequest();
    await _sendRequest(request, retry: false);
  }

  Future<void> _onRetry() async {
    final req = _lastFailedRequest;
    if (req == null) return;
    await _sendRequest(req, retry: true);
  }

  Future<void> _sendRequest(
    LectureSubmitRequest request, {
    required bool retry,
  }) async {
    setState(() {
      _status = _LectureStatus.submitting;
      _errorMessage = null;
      if (!retry) {
        _round += 1;
        _turns.add(AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '已收到第 $_round 轮讲解，AI 同伴正在阅读你的步骤、写追问……',
          highlightStepIds: const [],
        ));
      }
    });
    _scrollToBottomSoon();

    try {
      final response = await _lectureService.submit(request);
      if (!mounted) return;

      // 第五轮：请求成功后，把本轮 student 历史项（即 request.history 的
      // **最后一条** —— 在 _buildRequest 里临时拼出来的那条）连同 AI 返回的
      // turns 一起一次性落入本地多轮历史。retry 复用同一个 request，所以
      // request.history.last 也是同一条 student 项，不会重复追加。
      final committedStudent = request.history.isNotEmpty
          ? request.history.last
          : null;
      final isCompleted = response.status == 'completed';

      setState(() {
        _turns.addAll(response.turns);
        _lastResponseStatus = response.status;
        _status = isCompleted
            ? _LectureStatus.finished
            : _LectureStatus.awaiting;
        _errorMessage = null;
        _lastFailedRequest = null;

        if (committedStudent != null && committedStudent.role == 'student') {
          _history.add(committedStudent);
        }
        for (final t in response.turns) {
          _history.add(_agentTurnToHistory(t));
        }
        // 历史只保留最近若干条；后端也会再做一次硬上限。
        if (_history.length > _maxHistoryItems) {
          _history.removeRange(0, _history.length - _maxHistoryItems);
        }

        if (isCompleted) {
          // 「这一题讲清楚了」：追加一条温和的系统收束气泡，文案与右下角
          // 完成横幅呼应；不自动清空画布，给学生留时间回看高亮。
          _turns.add(const AgentTurn(
            role: AgentRole.system,
            displayName: '系统',
            text: '这一题讲清楚了。可以点「下一题」继续，也可以点「再讲一遍」复盘。',
            highlightStepIds: [],
          ));
        }
      });

      final highlightFromFirst =
          response.turns.expand((t) => t.highlightStepIds).toSet();
      if (highlightFromFirst.isNotEmpty) {
        _canvasController.setHighlight(highlightFromFirst);
      }
      _scrollToBottomSoon();
    } on LectureApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _LectureStatus.error;
        _errorMessage = e.userMessage;
        _lastFailedRequest = request;
        if (!retry && _turns.isNotEmpty && _turns.last.role == AgentRole.system) {
          _turns.removeLast();
        }
      });
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _LectureStatus.error;
        _errorMessage = '出现未知错误：$e';
        _lastFailedRequest = request;
        if (!retry && _turns.isNotEmpty && _turns.last.role == AgentRole.system) {
          _turns.removeLast();
        }
      });
      _scrollToBottomSoon();
    }
  }

  void _onUnderstood() {
    setState(() {
      _turns.add(const AgentTurn(
        role: AgentRole.teacher,
        displayName: '李老师',
        text: '好。这一轮先到这里。下一题我们换一种条件，看你能不能用刚才总结的思路再讲一次。',
        highlightStepIds: [],
      ));
      _status = _LectureStatus.finished;
    });
    _canvasController.clearHighlight();
    _scrollToBottomSoon();
  }

  void _onContinue() {
    _canvasController.clear();
    // 「下一题」语义 = 重新开始一题，所以学生上一题的口述与步骤说明也清空。
    // 第五轮：本题的多轮历史也一并清空（见 brief 6.1 节）。
    // 提交失败 / 错误重试时**不**走这里，仍保留输入（见 `_sendRequest` 错误分支）。
    _speechController.clear();
    for (final c in _stepPlainControllers.values) {
      c.clear();
    }
    for (final c in _stepLatexControllers.values) {
      c.clear();
    }
    _stepLatexExpanded.clear();
    setState(() {
      _status = _LectureStatus.idle;
      _errorMessage = null;
      _lastFailedRequest = null;
      _turns
        ..clear()
        ..add(_introTurn());
      _history.clear();
      _round = 0;
      _lastResponseStatus = 'needs_explanation';
    });
  }

  /// 「再讲一遍」：保留同一道题，但清空多轮历史 / 画布 / 输入区，让学生
  /// 重新开口讲一遍。第五轮 `completed` 状态下提供这个入口，方便复盘。
  void _onReplay() {
    _canvasController.clear();
    _speechController.clear();
    for (final c in _stepPlainControllers.values) {
      c.clear();
    }
    for (final c in _stepLatexControllers.values) {
      c.clear();
    }
    _stepLatexExpanded.clear();
    setState(() {
      _status = _LectureStatus.idle;
      _errorMessage = null;
      _lastFailedRequest = null;
      _turns
        ..clear()
        ..add(_introTurn())
        ..add(const AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '好，再讲一遍。这次你可以试着用更精炼的语言总结，每一步都说清「为什么这样做」。',
          highlightStepIds: [],
        ));
      _history.clear();
      _round = 0;
      _lastResponseStatus = 'needs_explanation';
    });
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_discussionScrollController.hasClients) return;
      _discussionScrollController.animateTo(
        _discussionScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 720;
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: Text(widget.section.label),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _MasteryBadge(round: _round)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(isWide ? AppSpacing.pageEdge : 16),
          child: isWide ? _buildWideLayout() : _buildNarrowLayout(),
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 40, child: _buildDiscussionPanel()),
        const SizedBox(width: AppSpacing.moduleGap),
        Expanded(flex: 60, child: _buildCanvasPanel()),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 5, child: _buildDiscussionPanel()),
        const SizedBox(height: AppSpacing.moduleGap),
        Expanded(flex: 7, child: _buildCanvasPanel()),
      ],
    );
  }

  Widget _buildDiscussionPanel() {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.forum_outlined, size: 20, color: AppPalette.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '多 Agent 讨论 · ${_question.sectionLabel}',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _QuestionCard(question: _question),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              controller: _discussionScrollController,
              itemCount: _turns.length +
                  (_status == _LectureStatus.submitting ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (index >= _turns.length) {
                  return const _ThinkingBubble();
                }
                final turn = _turns[index];
                return AgentMessageBubble(
                  turn: turn,
                  isHighlighted: turn.highlightStepIds
                      .any(_canvasController.highlightStepIds.contains),
                  onHighlightTap: turn.highlightStepIds.isEmpty
                      ? null
                      : () => _canvasController.setHighlight(turn.highlightStepIds),
                );
              },
            ),
          ),
          if (_status == _LectureStatus.error && _errorMessage != null) ...[
            const SizedBox(height: 12),
            _ErrorBanner(message: _errorMessage!, onRetry: _onRetry),
          ],
          // 第五轮：completed 状态下，先显示一条温和的「这一题讲清楚了」横幅，
          // 再展示「再讲一遍 / 下一题」两个对等动作；不自动清空画布，给学生
          // 留时间回看高亮。
          if (_status == _LectureStatus.finished &&
              _lastResponseStatus == 'completed') ...[
            const SizedBox(height: 12),
            const _CompletionBanner(),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _onReplay,
                    icon: const Icon(Icons.history),
                    label: const Text('再讲一遍'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _onContinue,
                    icon: const Icon(Icons.east),
                    label: const Text('下一题'),
                  ),
                ),
              ],
            ),
          ] else if (_status == _LectureStatus.awaiting ||
              _status == _LectureStatus.finished) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _onUnderstood,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('我懂了'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _onContinue,
                    icon: const Icon(Icons.refresh),
                    label: const Text('下一题'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCanvasPanel() {
    final canSubmit = (_status == _LectureStatus.idle ||
            _status == _LectureStatus.awaiting ||
            _status == _LectureStatus.error) &&
        !_canvasController.isEmpty;
    final submitting = _status == _LectureStatus.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.edit_outlined, size: 20, color: AppPalette.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '手写板 · 写出你的解题步骤',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AnimatedBuilder(
              animation: _canvasController,
              builder: (context, _) {
                final count = _canvasController.collectStepIds().length;
                return Text(
                  count == 0 ? '尚未书写' : '已识别 $count 步',
                  style: Theme.of(context).textTheme.bodySmall,
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: HandCanvas(controller: _canvasController)),
        const SizedBox(height: 12),
        // 第四轮新增「学生语义输入区」：讲解文字 + 每步说明 + 选填 LaTeX。
        // 用 ConstrainedBox 控住最大高度，避免占掉太多手写板主体空间；
        // 内部用 SingleChildScrollView 防止键盘弹起时溢出。
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: _canvasController,
              builder: (context, _) => _buildSemanticInputsPanel(context),
            ),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedBuilder(
          animation: _canvasController,
          builder: (context, _) {
            return Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _canvasController.canUndo && !submitting
                      ? _canvasController.undo
                      : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('撤销'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _canvasController.isEmpty || submitting
                      ? null
                      : _canvasController.clear,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('清空'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: canSubmit && !submitting ? _onSubmit : null,
                  icon: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(_status == _LectureStatus.error
                          ? Icons.replay
                          : Icons.send_outlined),
                  label: Text(_submitLabel(submitting)),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 「我刚才是这样讲的」+「为每一步补充一句话」输入区。
  ///
  /// 第四轮目标：在不接 ASR/OCR 之前，先让学生把自己的解法语义带进
  /// `studentSpeechText` 与 `steps[*].plainText / latex`，给后端 LLM
  /// 真东西可读，而不是只看到光秃秃的笔画数。
  ///
  /// 第五轮新增：当本题已经发生过 AI 追问（[_pendingAiFollowupTurn] 非空）时,
  /// 把输入区的标题/副标题/placeholder 改为「回答 X 的追问」语境，让学生明确
  /// 自己接下来该写的是「回答」，而不是「重新讲一遍」。
  Widget _buildSemanticInputsPanel(BuildContext context) {
    final stepIds = _canvasController.collectStepIds();
    _ensureStepControllers(stepIds);
    final theme = Theme.of(context);

    final pendingFollowup = _pendingAiFollowupTurn;
    final hasFollowup = pendingFollowup != null;
    final speechTitle =
        hasFollowup ? '回答${pendingFollowup.displayName}的追问' : '我刚才是这样讲的';
    final speechSubtitle =
        hasFollowup ? 'AI 同伴会先评估你的回答' : 'AI 同伴会照着这段话追问';
    final speechHint = hasFollowup
        ? '例如：因为 12=4×3，4 是完全平方数，所以可以把 2 提出来……'
        : '例如：我先把 12 拆成 4×3，所以根号 12 可以化成 2 根号 3……';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                hasFollowup
                    ? Icons.question_answer_outlined
                    : Icons.record_voice_over_outlined,
                size: 18,
                color: AppPalette.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(speechTitle, style: theme.textTheme.titleSmall),
              ),
              Flexible(
                child: Text(
                  speechSubtitle,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (hasFollowup) ...[
            const SizedBox(height: 6),
            _PendingFollowupHint(turn: pendingFollowup),
          ],
          const SizedBox(height: 8),
          _SoftTextField(
            controller: _speechController,
            minLines: 2,
            maxLines: 4,
            hintText: speechHint,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.format_list_numbered_outlined,
                  size: 18, color: AppPalette.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '为每一步补充一句话（可选）',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (stepIds.isNotEmpty)
                Text(
                  '共 ${stepIds.length} 步',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (stepIds.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '在右侧手写后，会自动出现每一步的说明输入框，可用一句中文写出这一步在做什么。',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < stepIds.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _buildStepInputRow(
                    context: context,
                    stepId: stepIds[i],
                    order: i + 1,
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildStepInputRow({
    required BuildContext context,
    required String stepId,
    required int order,
  }) {
    final plainController = _stepPlainControllers[stepId]!;
    final latexController = _stepLatexControllers[stepId]!;
    final latexExpanded = _stepLatexExpanded.contains(stepId);

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
      decoration: BoxDecoration(
        color: AppPalette.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _StepOrderBadge(order: order),
              const SizedBox(width: 10),
              Expanded(
                child: _SoftTextField(
                  controller: plainController,
                  minLines: 1,
                  maxLines: 2,
                  dense: true,
                  hintText: '例如：根号 12 化成 2 根号 3',
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (latexExpanded) {
                      _stepLatexExpanded.remove(stepId);
                    } else {
                      _stepLatexExpanded.add(stepId);
                    }
                  });
                },
                icon: Icon(
                  latexExpanded
                      ? Icons.expand_less
                      : Icons.functions_outlined,
                  size: 16,
                ),
                label: Text(latexExpanded ? '收起' : '加公式'),
                style: TextButton.styleFrom(
                  foregroundColor: AppPalette.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (latexExpanded) ...[
            const SizedBox(height: 8),
            _SoftTextField(
              controller: latexController,
              minLines: 1,
              maxLines: 2,
              dense: true,
              monospace: true,
              hintText: r'可选 LaTeX：\sqrt{12}=2\sqrt{3}',
            ),
          ],
        ],
      ),
    );
  }

  String _submitLabel(bool submitting) {
    // 第三轮起 `/lecture/submit` 内部会真实调用 Kimi，端到端常常 8-15s。
    // 文案换成「AI 同伴思考中…」让学生知道这次是真的在等模型，而不是 0.5s
    // 假 loading 的固定 Mock。
    if (submitting) return 'AI 同伴思考中…';
    if (_status == _LectureStatus.error) return '重新提交';
    if (_round == 0) return '提交讲解';
    // 第五轮：如果有 AI 追问待回答，按钮文案切到「回答追问」语境，让学生
    // 明确「这次提交是在回答 X 的问题」而不是「重头再讲一遍」。
    if (_pendingAiFollowupTurn != null) return '回答追问';
    return '再讲一轮';
  }
}

/// 输入区上方的「待回答 AI 追问」轻量提示卡：用引号简要复述 AI 上一句话，
/// 让学生在写回答前能快速回看自己要解决的问题。
///
/// 第五轮新增。仅在 `_status` 为 awaiting / error 且本题已有 AI 追问时展示。
class _PendingFollowupHint extends StatelessWidget {
  const _PendingFollowupHint({required this.turn});

  final AgentTurn turn;

  @override
  Widget build(BuildContext context) {
    final preview = turn.text.length > 80
        ? '${turn.text.substring(0, 80)}…'
        : turn.text;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppPalette.primary.withValues(alpha: 0.20),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.help_outline,
              size: 16, color: AppPalette.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${turn.displayName}刚问：「$preview」',
              style: const TextStyle(
                color: AppPalette.primary,
                fontSize: 12.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「这一题讲清楚了」收束横幅：第五轮新增，仅在后端返回
/// `status: completed` 时展示，与下方「再讲一遍 / 下一题」按钮联动。
class _CompletionBanner extends StatelessWidget {
  const _CompletionBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppPalette.primaryAccent.withValues(alpha: 0.10),
        borderRadius: AppRadius.cardR,
        border: Border.all(
          color: AppPalette.primaryAccent.withValues(alpha: 0.36),
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.celebration_outlined,
            size: 20,
            color: AppPalette.primaryAccent,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '这一题讲清楚了。可以点「下一题」继续，也可以点「再讲一遍」自己复盘。',
              style: TextStyle(
                color: AppPalette.primaryAccent,
                fontWeight: FontWeight.w600,
                height: 1.45,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppPalette.error.withValues(alpha: 0.08),
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppPalette.error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppPalette.error,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.error,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question});

  final LectureQuestion question;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.06),
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_outlined,
                  size: 16, color: AppPalette.primary),
              const SizedBox(width: 6),
              Text(
                '今日题目',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: AppPalette.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FormulaText(
            question.prompt,
            style: Theme.of(context).textTheme.bodyLarge,
            formulaStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppPalette.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          FormulaText(
            question.hint,
            style: Theme.of(context).textTheme.bodySmall,
            formulaStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.primaryAccent,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.06),
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppPalette.primary,
              backgroundColor: AppPalette.primary.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'AI 同伴正在阅读你的步骤、写追问……',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// 温和「纸张」风格输入框，遵循 `MOBILE_STYLE.md`：
///   * 浅米白底 + 1dp 柔和描边，不要冷调灰；
///   * 圆角 12，焦点态用 primary 提亮但不过分；
///   * 触控热区随父高度自适应，外层调用方负责 `minLines/maxLines`。
class _SoftTextField extends StatelessWidget {
  const _SoftTextField({
    required this.controller,
    required this.hintText,
    this.minLines = 1,
    this.maxLines = 2,
    this.dense = false,
    this.monospace = false,
  });

  final TextEditingController controller;
  final String hintText;
  final int minLines;
  final int maxLines;
  final bool dense;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      textInputAction:
          maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
      style: base?.copyWith(
        fontFamily: monospace ? 'monospace' : base.fontFamily,
        color: AppPalette.textPrimary,
      ),
      cursorColor: AppPalette.primary,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(
          color: AppPalette.textSecondary.withValues(alpha: 0.75),
          fontSize: dense ? 13 : 14,
          height: 1.4,
        ),
        isDense: dense,
        filled: true,
        fillColor: AppPalette.background,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: dense ? 10 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.outlineSoft),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.outlineSoft),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.primary, width: 1.4),
        ),
      ),
    );
  }
}

class _StepOrderBadge extends StatelessWidget {
  const _StepOrderBadge({required this.order});

  final int order;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppPalette.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Text(
        '$order',
        style: const TextStyle(
          color: AppPalette.primary,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _MasteryBadge extends StatelessWidget {
  const _MasteryBadge({required this.round});

  final int round;

  @override
  Widget build(BuildContext context) {
    final label = round == 0 ? '理解中' : '已完成 $round 轮';
    final color = round == 0 ? AppPalette.textSecondary : AppPalette.primaryAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
