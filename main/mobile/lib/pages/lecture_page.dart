import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/curriculum_models.dart';
import '../data/lecture_models.dart';
import '../data/live_lecture_events.dart';
import '../data/mock_lecture_repository.dart';
import '../data/progress_models.dart';
import '../data/review_models.dart';
import '../services/audio_stream_service.dart';
import '../services/auth_service.dart';
import '../services/learning_sync_service.dart';
import '../services/lecture_service.dart';
import '../services/live_lecture_service.dart';
import '../services/ocr_service.dart';
import '../services/progress_repository.dart';
import '../services/replay_service.dart';
import '../services/review_repository.dart';
import '../services/user_cosmetics_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/agent_message_bubble.dart';
import '../widgets/formula_text.dart';
import '../widgets/hand_canvas.dart';
import '../widgets/realtime_audio_panel.dart';
import 'privacy_notice_page.dart';

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
    this.initialQuestionId,
    this.initialQuestionIndex,
  });

  final CurriculumSection section;

  /// 第八轮：可选的初始 `questionId`，用于「再讲这题」回到指定题目。
  ///
  /// 命中题库时优先于 [initialQuestionIndex]；未命中（题库被改 / 老 review
  /// 残留）时回落到 [initialQuestionIndex]，再不行回落到第 1 题。
  final String? initialQuestionId;

  /// 第八轮：可选的初始题目索引（0 起算）。当 [initialQuestionId] 未提供
  /// 或未命中时使用。允许任意整数，超出范围时按 modulo 循环（与第七轮
  /// `MockLectureRepository.questionForSection` 的 index 行为一致）。
  final int? initialQuestionIndex;

  @override
  State<LecturePage> createState() => _LecturePageState();
}

enum _LectureStatus { idle, submitting, awaiting, error, finished }

/// 第九轮：是否默认在白板下方展示"文字提交兜底"入口。
///
/// brief 第 9 节明确"禁止默认展示文字输入框，但允许白板-only 兜底提交"。
/// 这个开关由 `--dart-define=LIVE_FALLBACK_TEXTINPUT=1` 控制（仅
/// debug/演示场景），不构建时保持 false 与正式 demo 同口径。
const bool _kShowLegacyTextInputByDefault = bool.fromEnvironment(
  'LIVE_FALLBACK_TEXTINPUT',
  defaultValue: false,
);

const bool _debugOcr = bool.fromEnvironment('DEBUG_OCR');

/// 实时讲题阶段的本地状态：
///   * `idle`：尚未点击「开始讲题」；
///   * `connecting`：WS 握手中；
///   * `listening`：WS 已连 + 录音流持续中；
///   * `paused`：学生静音 ≥ 1.5s（来自 [AudioStreamService.statusStream]）；
///   * `thinking`：已经发了 `pause_detected`，等 AI 思考；
///   * `aiSpeaking`：有未完成的 agent_turn / TTS 在播；
///   * `disconnected`：WS 断开（保留白板，可重连）；
///   * `permissionDenied`：麦克风权限被拒绝；
///   * `failed`：录音库 / WS 严重错误；
///
/// **不**与 [_LectureStatus] 合并：后者描述文字提交路径的提交
/// 状态机；这两个状态机互相独立、可同时存在。
enum _LiveStatus {
  idle,
  connecting,
  listening,
  paused,
  thinking,
  aiSpeaking,
  disconnected,
  permissionDenied,
  failed,
}

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

  /// 第七轮：本节题库与当前题目索引。
  ///
  /// `_questions` 在 [initState] 一次性从 [MockLectureRepository] 拉满，
  /// 后续切题只动 `_questionIndex`（modulo 循环），不重复访问仓库。
  /// `_question` 是 `_questions[_questionIndex]` 的快照，便于讨论区
  /// AppBar 标题、题面卡片、intro 气泡同时引用同一份数据。
  late List<LectureQuestion> _questions;
  int _questionIndex = 0;
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

  /// 第六轮：本节最新本地进度快照（来自 [ProgressRepository]），用于完成态
  /// 卡片显示「本节掌握度 +X，当前 N/100」。`null` 表示尚未发生过 completed。
  SectionProgress? _sectionProgressAfterCompletion;

  /// 本次 completed 实际加了多少掌握度（已考虑 100 上限）。
  int _lastMasteryGain = 0;

  /// 本次 completed 的小结文案（前端拼装：最后一条 teacher / AI turn）。
  String _lastSummary = '';

  /// 第八轮：本轮 completed 是否已经写过 review 记录。
  ///
  /// `_persistCompletion` 只会在 `_sendRequest` 成功分支里被调用，理论上不会
  /// 在 setState 重建里被重复触发；这个 flag 是双保险：万一未来代码改成
  /// 「在 listener 里轮询 completed」也不至于一秒内连续写多条 review 记录。
  /// 在 [_resetTransientState]（下一题 / 再讲一遍）里被重置为 false。
  bool _reviewSavedForCurrentRound = false;

  /// 本地历史最多保留多少条。后端也会再做一次硬上限。
  static const int _maxHistoryItems = 6;

  // —— 第九轮：实时双工讲题相关状态 ————————————————————————————————————
  final AudioStreamService _audioService = AudioStreamService();
  final LiveLectureService _liveService = LiveLectureService();
  final ReplayService _replayService = ReplayService();

  _LiveStatus _liveStatus = _LiveStatus.idle;
  String? _liveFailureReason;

  /// 当前正在被流式增量的 AI turn id；空字符串表示当前没有未完成 turn。
  String _activeStreamingTurnId = '';
  bool _ttsPlaying = false;
  Timer? _inkSnapshotDebounce;
  Timer? _interruptCooldownTimer;
  Timer? _stuckHintTimer;
  Timer? _wrapUpTimer;
  Timer? _voiceDebounceTimer;
  bool _interruptOnCooldown = false;
  bool _stuckHintShownForPause = false;

  late final StreamSubscription _liveEventsSub;
  late final StreamSubscription _liveErrorsSub;
  late final StreamSubscription _liveConnSub;
  late final StreamSubscription _liveTtsSub;
  late final StreamSubscription _audioChunksSub;
  late final StreamSubscription _audioPausesSub;
  late final StreamSubscription _audioVoiceSub;
  late final StreamSubscription _audioStatusSub;

  @override
  void initState() {
    super.initState();
    final repo = MockLectureRepository.instance;
    // 第七轮：题库一次性加载，后续翻题只动 [_questionIndex] —— 仓库本身
    // 是不可变 const list，多次调用 questionsForSection 也安全，但保留
    // 一份快照能让讲题页所有 sub-widget 看到的题序保持一致。
    _questions = repo.questionsForSection(widget.section.id);
    // 第八轮：优先用 widget.initialQuestionId 定位（来自回顾页「再讲这题」）,
    // 命中失败时回落 widget.initialQuestionIndex，再不行回落第 1 题。
    _questionIndex = _resolveInitialQuestionIndex();
    if (widget.initialQuestionId == null && widget.initialQuestionIndex == null) {
      _questionIndex = _recommendedInitialQuestionIndex();
    }
    _question = _questions.isEmpty
        ? repo.questionForSection(widget.section.id)
        : _questions[_questionIndex];
    _turns.add(_introTurn());
    _canvasController.addListener(_onCanvasChanged);
    _wireLiveServices();
    UserCosmeticsPrefs.instance.load();
  }

  /// 把 [_audioService] 与 [_liveService] 的所有事件流串到 setState 上。
  ///
  /// 这些 subscription 在 [dispose] 里统一 cancel，避免 leak。
  void _wireLiveServices() {
    _liveEventsSub = _liveService.events.listen(_onLiveEvent);
    _liveErrorsSub = _liveService.errors.listen(_onLiveServiceError);
    _liveConnSub = _liveService.connectionState.listen(_onLiveConnection);
    _liveTtsSub = _liveService.ttsState.listen(_onTtsState);
    _audioChunksSub = _audioService.chunks.listen(_onAudioChunk);
    _audioPausesSub = _audioService.pauses.listen(_onAudioPause);
    _audioVoiceSub = _audioService.voiceActivity.listen(_onAudioVoice);
    _audioStatusSub = _audioService.statusStream.listen(_onAudioStatus);
  }

  /// 解析 [LecturePage.initialQuestionId] / [LecturePage.initialQuestionIndex]
  /// 为合法的 `_questionIndex`（已经做过 modulo 与空题库防御）。
  ///
  /// 第八轮新增。被 [initState] 一次性调用，并不暴露给后续切题逻辑。
  int _resolveInitialQuestionIndex() {
    if (_questions.isEmpty) return 0;
    final wantedId = widget.initialQuestionId;
    if (wantedId != null && wantedId.isNotEmpty) {
      for (var i = 0; i < _questions.length; i++) {
        if (_questions[i].questionId == wantedId) return i;
      }
    }
    final raw = widget.initialQuestionIndex;
    if (raw == null) return 0;
    // 与第七轮 `MockLectureRepository.questionForSection` 同口径：负数 /
    // 越界都走 modulo，不抛异常 —— Dart 的 `%` 对负数返回非负余数。
    return raw % _questions.length;
  }

  int _recommendedInitialQuestionIndex() {
    if (_questions.isEmpty) return 0;
    final mastery =
        ProgressRepository.instance.progressFor(widget.section.id).masteryScore;
    final preferred = mastery >= 60 ? 3 : (mastery >= 30 ? 2 : 1);
    for (var i = 0; i < _questions.length; i++) {
      if (_questions[i].difficulty >= preferred) return i;
    }
    return 0;
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
    unawaited(_replayService.finishAndUpload());
    _replayService.close();
    // 第九轮：实时讲题资源全部释放。subscription cancel 顺序不重要，但
    // _liveService / _audioService 的 dispose 必须 await 才能真正关闭
    // WS 句柄；这里走 unawaited，因为 dispose 不能是 async。
    _inkSnapshotDebounce?.cancel();
    _interruptCooldownTimer?.cancel();
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
    _voiceDebounceTimer?.cancel();
    unawaited(_liveEventsSub.cancel());
    unawaited(_liveErrorsSub.cancel());
    unawaited(_liveConnSub.cancel());
    unawaited(_liveTtsSub.cancel());
    unawaited(_audioChunksSub.cancel());
    unawaited(_audioPausesSub.cancel());
    unawaited(_audioVoiceSub.cancel());
    unawaited(_audioStatusSub.cancel());
    unawaited(_audioService.dispose());
    unawaited(_liveService.dispose());
    super.dispose();
  }

  /// 监听手写板变化：
  ///   * 画板被清空（`isEmpty`）时把所有步骤说明输入框文本归零，
  ///     而不是销毁 controller（销毁会让 [TextField] state 报错）。
  ///   * 出现新 stepId 时不在这里建 controller，留给 [_ensureStepControllers]
  ///     在 build 阶段 lazy 创建，避免在 listener 里 setState 抖动。
  void _onCanvasChanged() {
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
    _stuckHintShownForPause = false;
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
    // 第九轮：白板任何更新都 debounce 500ms 后给后端发一次 snapshot；
    // 同时如果 AI 正在说话，落笔即打断（brief 第 11 节）。
    _scheduleInkSnapshot();
    if (_ttsPlaying || _liveStatus == _LiveStatus.aiSpeaking) {
      _maybeInterruptAi(reason: 'pen');
    }
  }

  void _scheduleInkSnapshot() {
    _inkSnapshotDebounce?.cancel();
    _inkSnapshotDebounce = Timer(const Duration(milliseconds: 480), () async {
      if (!mounted) return;
      if (!_liveService.isConnected) return;
      final stepInfos = _canvasController.collectStepInfos();
      if (stepInfos.isEmpty) return;
      final steps = <Map<String, dynamic>>[];
      for (final info in stepInfos) {
        final png = await _canvasController.exportStepPng(info.stepId);
        steps.add({
          'stepId': info.stepId,
          'strokeCount': info.strokeCount,
          'boundingBox': {
            'x': info.bounds.left.isFinite ? info.bounds.left : 0,
            'y': info.bounds.top.isFinite ? info.bounds.top : 0,
            'width':
                info.bounds.width.isFinite && info.bounds.width > 0
                    ? info.bounds.width
                    : 1,
            'height':
                info.bounds.height.isFinite && info.bounds.height > 0
                    ? info.bounds.height
                    : 1,
          },
          'imageBase64': png == null ? '' : base64Encode(png),
          'latex': '',
          'plainText': '',
        });
      }
      _liveService.sendInkSnapshot(steps);
      _replayService.appendInk(steps);
    });
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

  /// intro 文案随当前题目刷新：第七轮起每节有 3 道题，老师开场白也要点出
  /// 「这是本节第几道题」+ 题目难度，让学生对接下来要讲的内容心里有数。
  AgentTurn _introTurn() {
    final order = _questions.isEmpty ? 1 : (_questionIndex + 1);
    final total = _questions.isEmpty ? 1 : _questions.length;
    final levelLabel = MockLectureRepository.instance
        .difficultyLabel(_question.difficulty);
    return AgentTurn(
      role: AgentRole.teacher,
      displayName: '李老师',
      text: '欢迎来到「${_question.sectionLabel}」讲题课，这是本节的第 $order / $total 题（$levelLabel）。'
          '请你在右侧手写板上写出你的解题步骤，边写边想；'
          '写完后点击「提交讲解」，小明和我会和你一起讨论。',
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
      // 第十轮：提交前先调一次 /ocr/ink 把空 latex/plainText 步骤补上,
      // 让 LLM 看到更密集的语义证据。OCR 失败时返回原 request，不影响主路径。
      final enriched = await _lectureService.enrichWithOcr(
        request,
        referenceSteps: _question.referenceSteps,
      );
      final response = await _lectureService.submit(enriched);
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

      // 第六轮：completed 时落地本地进度。
      //   * 不阻塞 UI：仓库内部串行化写盘，仅在写盘完成后通知首页订阅者
      //     刷新「已完成 N 轮 · 掌握度 X/100」。
      //   * 本题小结优先取「本轮 + 历史」里最后一条 teacher turn，没有就取
      //     最后一条 AI turn；都没有用兜底文案。
      if (isCompleted) {
        unawaited(_persistCompletion(response));
      }
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

  /// 把 [response] 折算为本节本地进度并落库，同时把「本题讲题小结」相关
  /// 字段写入 state，供完成态卡片渲染。
  ///
  /// 第六轮新增。所有失败都被仓库吞掉并打 log，**不**抛回 UI —— brief 第 8
  /// 节明确要求「不要因为 progress 读取失败影响课程目录展示。失败时可以当
  /// 作空进度」，这里在写入侧也保持同样口径。
  Future<void> _persistCompletion(LectureSubmitResponse response) async {
    final summary = _composeCompletionSummary(response.turns);
    final result = await ProgressRepository.instance.applyCompleted(
      sectionId: widget.section.id,
      masteryDelta: response.masteryDelta,
      summary: summary,
    );
    if (!mounted) return;
    setState(() {
      _sectionProgressAfterCompletion = result.next;
      _lastMasteryGain = result.gained;
      _lastSummary = summary;
    });
    // 第八轮：progress 落库（成功或失败都已经走完）之后再写 review 记录。
    // 仓库内部已经吞掉所有写入异常，这里不需要 try/catch；按 brief 第 8
    // 节「如果保存 review 失败，掌握度仍应正常更新」—— progress 已先更新。
    if (!_reviewSavedForCurrentRound) {
      _reviewSavedForCurrentRound = true;
      await _persistReview(response: response, summary: summary);
    }
    // 第十轮：登录后才同步；未登录时静默跳过。失败不弹错。
    if (AuthService.instance.isLoggedIn) {
      unawaited(LearningSyncService.instance.syncNow());
    }
  }

  /// 第八轮：保存本题的回顾记录。
  ///
  /// 设计：
  ///   * `agentHighlights` 从「本轮 response.turns + 已有 _turns 历史」按
  ///     倒序找最近 1-3 条非 system 的 AI turn，截短到约 80 字，避免回顾
  ///     卡片被一段长追问撑成多行；
  ///   * `cautionPoints` 调用 `ReviewRepository.derivCautionPoints` —— 纯
  ///     标签规则，不引入 LLM；
  ///   * `id` 用 `'$questionId-$millis'`，便于人眼对账。
  Future<void> _persistReview({
    required LectureSubmitResponse response,
    required String summary,
  }) async {
    final highlights = _composeAgentHighlights(response.turns);
    final cautions = ReviewRepository.derivCautionPoints(
      tags: _question.tags,
      summary: summary,
    );
    final now = DateTime.now();
    final record = LectureReviewRecord(
      id: '${_question.questionId}-${now.millisecondsSinceEpoch}',
      sectionId: widget.section.id,
      questionId: _question.questionId,
      questionPrompt: _question.prompt,
      difficulty: _question.difficulty,
      tags: List<String>.unmodifiable(_question.tags),
      completedAt: now,
      summary: summary,
      agentHighlights: highlights,
      cautionPoints: cautions,
    );
    await ReviewRepository.instance.append(record);
    unawaited(LearningSyncService.instance.postReview(record));
  }

  /// 从本轮 + 历史 turns 中抽取 1-3 条「AI 同伴聊了什么」短文本。
  ///
  /// 规则：
  ///   * 倒序遍历，先看本轮 `latestTurns`，再看页面已有的 `_turns`；
  ///   * 过滤 system / 空文本；
  ///   * 去重（按整段文本）；
  ///   * 每条截断到 80 字以内，末尾加省略号；
  ///   * 最多保留 3 条 —— 与回顾卡片设计一致，避免拥挤。
  List<String> _composeAgentHighlights(List<AgentTurn> latestTurns) {
    const int maxItems = 3;
    const int maxChars = 80;
    final out = <String>[];

    void consider(AgentTurn t) {
      if (out.length >= maxItems) return;
      if (t.role == AgentRole.system) return;
      final text = t.text.trim();
      if (text.isEmpty) return;
      final clipped =
          text.length <= maxChars ? text : '${text.substring(0, maxChars)}…';
      if (out.contains(clipped)) return;
      out.add(clipped);
    }

    for (final t in latestTurns.reversed) {
      consider(t);
      if (out.length >= maxItems) break;
    }
    if (out.length < maxItems) {
      for (final t in _turns.reversed) {
        consider(t);
        if (out.length >= maxItems) break;
      }
    }
    return List.unmodifiable(out);
  }

  /// 优先级：本轮最后一条 teacher turn → 本轮最后一条 AI turn →
  /// 本题历史里最后一条 teacher → 历史里最后一条 AI → 兜底文案。
  ///
  /// 不为了总结再调一次 LLM（brief 第 7 节明确禁止），所以拼装逻辑必须
  /// **稳定** —— 任何一道 16.x 题在 completed 时都要能拼出一条「像样的
  /// 小结」给学生看。
  String _composeCompletionSummary(List<AgentTurn> latestTurns) {
    String? findTeacher(Iterable<AgentTurn> turns) {
      for (final t in turns.toList().reversed) {
        if (t.role == AgentRole.teacher && t.text.trim().isNotEmpty) {
          return t.text.trim();
        }
      }
      return null;
    }

    String? findAnyAi(Iterable<AgentTurn> turns) {
      for (final t in turns.toList().reversed) {
        if (t.role != AgentRole.system && t.text.trim().isNotEmpty) {
          return t.text.trim();
        }
      }
      return null;
    }

    final teacherInLatest = findTeacher(latestTurns);
    if (teacherInLatest != null) return teacherInLatest;
    final aiInLatest = findAnyAi(latestTurns);
    if (aiInLatest != null) return aiInLatest;

    // 历史里的 AgentTurn 已经在 _turns 里追加过；从 _turns 里再扫一遍即可。
    final teacherInAll = findTeacher(_turns);
    if (teacherInAll != null) return teacherInAll;
    final aiInAll = findAnyAi(_turns);
    if (aiInAll != null) return aiInAll;

    return '本题已完成一轮讲解，建议回看高亮步骤，总结这一步为什么成立。';
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

  /// 把"切下一题 / 再讲一遍"两个入口共用的临时态清理动作集中到这里：
  ///
  /// - 画板、高亮、撤销栈
  /// - 学生口述 + 每步说明 + LaTeX 展开
  /// - 多轮 `_history`、`_turns`、`_round`
  /// - 错误状态、最近一次失败请求快照
  /// - 第六轮完成态卡片字段（progress / gain / summary）
  ///
  /// 注意：**不**清空 [ProgressRepository] 仓库（学生只是要换一题或复盘，
  /// 不是要抹掉学习记录）。
  void _resetTransientState() {
    _canvasController.clear();
    _speechController.clear();
    for (final c in _stepPlainControllers.values) {
      c.clear();
    }
    for (final c in _stepLatexControllers.values) {
      c.clear();
    }
    _stepLatexExpanded.clear();
    _status = _LectureStatus.idle;
    _errorMessage = null;
    _lastFailedRequest = null;
    _history.clear();
    _round = 0;
    _lastResponseStatus = 'needs_explanation';
    _sectionProgressAfterCompletion = null;
    _lastMasteryGain = 0;
    _lastSummary = '';
    // 第八轮：进入新一轮后允许再次保存 review 记录（再讲一遍同题 / 下一题
    // 都属于「新一轮」语义；不重置会导致连续两题只留下第一题的回顾）。
    _reviewSavedForCurrentRound = false;
  }

  /// 第七轮：「下一题」=切到本节题库的下一道题。索引循环（第 3 题点下一题
  /// 回到第 1 题），同时清空所有临时态、重置 intro 气泡、引用新题面。
  ///
  /// 提交失败 / 错误重试时**不**走这里，仍保留输入（见 `_sendRequest` 错误分支）。
  void _onContinue() {
    _resetTransientState();
    setState(() {
      if (_questions.isNotEmpty) {
        _questionIndex = (_questionIndex + 1) % _questions.length;
        _question = _questions[_questionIndex];
      }
      _turns
        ..clear()
        ..add(_introTurn());
    });
  }

  /// 「再讲一遍」：保留**同一道题**，但清空多轮历史 / 画布 / 输入区,
  /// 让学生重新开口讲一遍。第五轮 `completed` 状态下提供这个入口，方便复盘。
  ///
  /// 与 [_onContinue] 的关键差异：题目索引 [_questionIndex] **不**变化，
  /// 题面、难度、标签都保持上一轮的内容。
  void _onReplay() {
    _resetTransientState();
    setState(() {
      _turns
        ..clear()
        ..add(_introTurn())
        ..add(const AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '好，再讲一遍。这次你可以试着用更精炼的语言总结，每一步都说清「为什么这样做」。',
          highlightStepIds: [],
        ));
    });
  }

  // ============================================================ //
  // 第九轮：实时讲题事件处理
  // ============================================================ //

  /// 点击「开始讲题」入口。
  ///
  /// 流程：
  ///   1. 进入 connecting 状态；
  ///   2. 调 [LiveLectureService.connectAndStart] 建立 WS + 发 session_start；
  ///   3. 同时启动 [AudioStreamService.start]（含权限申请）；
  ///   4. 任一失败回落到 `disconnected` / `permissionDenied` / `failed` 状态，
  ///      白板不动，可点「用文字提交」走 [_onSubmit] 的 `/lecture/submit` 兜底；
  ///   5. 都成功 → 等待麦克风事件驱动状态机进 listening。
  Future<void> _onStartLive() async {
    if (!mounted) return;
    final acknowledged = await PrivacyNoticePage.ensureAcknowledged(context);
    if (!mounted || !acknowledged) return;
    setState(() {
      _liveStatus = _LiveStatus.connecting;
      _liveFailureReason = null;
    });
    final sessionId = 'sess-${DateTime.now().millisecondsSinceEpoch}-'
        '${widget.section.id}-${_question.questionId}';
    _replayService.startSession(
      sessionId: sessionId,
      sectionId: widget.section.id,
      questionId: _question.questionId,
      questionPrompt: _question.prompt,
    );
    final connected = await _liveService.connectAndStart(
      sessionId: sessionId,
      sectionId: widget.section.id,
      questionId: _question.questionId,
      questionPrompt: _question.prompt,
      referenceSteps: _question.referenceSteps,
    );
    if (!mounted) return;
    if (!connected) {
      setState(() {
        _liveStatus = _LiveStatus.disconnected;
        _liveFailureReason = '连不上后端 WebSocket，可以点「用文字提交」兜底。';
      });
      return;
    }
    final audioStarted = await _audioService.start();
    if (!mounted) return;
    if (!audioStarted) {
      // 录音失败：保留 WS 让学生还能手动「我讲到这里」，但状态切到失败态。
      final next = _audioService.status == AudioStreamStatus.permissionDenied
          ? _LiveStatus.permissionDenied
          : _LiveStatus.failed;
      setState(() {
        _liveStatus = next;
        _liveFailureReason = _audioService.failureReason ?? '录音不可用';
      });
      return;
    }
    // 启动成功后立刻把当前白板 snapshot 发出去，让后端在第一时间知道
    // 「学生目前有几步、笔画数」，不要等 debounce 触发。
    _scheduleInkSnapshot();
    setState(() {
      _liveStatus = _LiveStatus.listening;
    });
  }

  /// 「我讲到这里」/「我来回答」按钮：手动触发 AI 追问。
  ///
  /// 等价于客户端主动发一个 pause_detected：后端收到后无视当前
  /// silenceMs 数值，直接走 LLM 调用。brief 第 12 节"学生点击『我讲到
  /// 这里』可手动触发追问"。
  void _onManualPause() {
    if (!_liveService.isConnected) return;
    _liveService.sendPauseDetected(silenceMs: 1500);
    setState(() {
      _liveStatus = _LiveStatus.thinking;
    });
  }

  /// 「暂停倾听」按钮：thinking 阶段允许学生取消本轮，回到 idle 重写白板。
  void _onStopLive() {
    unawaited(_audioService.stop());
    unawaited(_liveService.stopTts());
    setState(() {
      _liveStatus = _LiveStatus.idle;
    });
  }

  /// 「结束本题」/「session_end」入口：关闭录音 + WS 会话，并切到非实时
  /// 兜底状态，让学生有机会用「下一题」继续。
  Future<void> _onEndLiveSession() async {
    _inkSnapshotDebounce?.cancel();
    await _audioService.stop();
    await _liveService.endSession();
    await _liveService.stopTts();
    if (!mounted) return;
    setState(() {
      _liveStatus = _LiveStatus.idle;
      _activeStreamingTurnId = '';
      _ttsPlaying = false;
    });
  }

  void _onAudioChunk(Uint8List data) {
    if (data.isEmpty) return;
    if (!_liveService.isConnected) return;
    _liveService.sendAudioBytes(data);
    _replayService.appendAudioChunk(base64Encode(data));
  }

  void _onAudioPause(int silenceMs) {
    if (!_liveService.isConnected) return;
    if (_liveStatus == _LiveStatus.thinking ||
        _liveStatus == _LiveStatus.aiSpeaking) {
      // brief 第 12 节"同一轮追问生成中忽略重复触发"
      return;
    }
    final lastStroke = _canvasController.lastStrokeAt;
    if (lastStroke != null &&
        DateTime.now().difference(lastStroke) < const Duration(seconds: 3)) {
      return;
    }
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
    _stuckHintTimer = Timer(
      Duration(milliseconds: (2500 - silenceMs).clamp(0, 2500).toInt()),
      _showStuckHintIfStillPaused,
    );
    _wrapUpTimer = Timer(
      Duration(milliseconds: (4000 - silenceMs).clamp(0, 4000).toInt()),
      () {
        if (!_liveService.isConnected || _liveStatus == _LiveStatus.thinking) {
          return;
        }
        final last = _canvasController.lastStrokeAt;
        if (last != null &&
            DateTime.now().difference(last) < const Duration(seconds: 3)) {
          return;
        }
        _liveService.sendPauseDetected(silenceMs: 4000);
        setState(() {
          _liveStatus = _LiveStatus.thinking;
        });
      },
    );
  }

  void _onAudioVoice(bool active) {
    if (!_liveService.isConnected) return;
    if (active) {
      _stuckHintTimer?.cancel();
      _wrapUpTimer?.cancel();
      _stuckHintShownForPause = false;
    }
    if (active && (_ttsPlaying || _liveStatus == _LiveStatus.aiSpeaking)) {
      _voiceDebounceTimer?.cancel();
      _voiceDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (_ttsPlaying || _liveStatus == _LiveStatus.aiSpeaking) {
          _maybeInterruptAi(reason: 'voice');
        }
      });
    } else if (active && _liveStatus == _LiveStatus.paused) {
      setState(() {
        _liveStatus = _LiveStatus.listening;
      });
    } else if (!active) {
      _voiceDebounceTimer?.cancel();
    }
  }

  void _showStuckHintIfStillPaused() {
    if (!mounted || _stuckHintShownForPause) return;
    if (_liveStatus == _LiveStatus.thinking || _liveStatus == _LiveStatus.aiSpeaking) return;
    final last = _canvasController.lastStrokeAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _stuckHintShownForPause = true;
    setState(() {
      _turns.add(const AgentTurn(
        role: AgentRole.teacher,
        displayName: '李老师',
        text: '卡住了也没关系。先想想：被开方数要满足什么条件？这一步为什么能这样化简？',
        highlightStepIds: [],
      ));
    });
    _scrollToBottomSoon();
  }

  void _onAudioStatus(AudioStreamStatus status) {
    if (!mounted) return;
    switch (status) {
      case AudioStreamStatus.permissionDenied:
        setState(() {
          _liveStatus = _LiveStatus.permissionDenied;
          _liveFailureReason = _audioService.failureReason ?? '麦克风权限被拒绝';
        });
        break;
      case AudioStreamStatus.failed:
        setState(() {
          _liveStatus = _LiveStatus.failed;
          _liveFailureReason = _audioService.failureReason ?? '录音库异常';
        });
        break;
      case AudioStreamStatus.paused:
        // 静音由 _onAudioPause 单独处理；这里只在 listening↔paused 之间切换
        if (_liveStatus == _LiveStatus.listening) {
          setState(() => _liveStatus = _LiveStatus.paused);
        }
        break;
      case AudioStreamStatus.listening:
        if (_liveStatus == _LiveStatus.paused ||
            _liveStatus == _LiveStatus.idle) {
          setState(() => _liveStatus = _LiveStatus.listening);
        }
        break;
      case AudioStreamStatus.idle:
        // 不主动切 _liveStatus —— idle 可能是被 _onStopLive 主动停的。
        break;
    }
  }

  void _maybeInterruptAi({required String reason}) {
    if (_interruptOnCooldown) return;
    _interruptOnCooldown = true;
    _interruptCooldownTimer?.cancel();
    _interruptCooldownTimer = Timer(const Duration(milliseconds: 700), () {
      _interruptOnCooldown = false;
    });
    if (_liveService.isConnected) {
      _liveService.sendStudentInterrupt(reason: reason);
    }
    unawaited(_liveService.stopTts());
    if (mounted) {
      setState(() {
        _ttsPlaying = false;
        _activeStreamingTurnId = '';
        _liveStatus = _LiveStatus.listening;
        final interruptedRole = _lastNonSystemRole();
        _turns.add(AgentTurn(
          role: interruptedRole,
          displayName: _defaultDisplayName(interruptedRole),
          text: _interruptMessageFor(interruptedRole),
          highlightStepIds: [],
        ));
      });
      _scrollToBottomSoon();
    }
  }

  void _onLiveEvent(LiveServerEvent event) {
    switch (event.type) {
      case LiveServerEventType.listening:
        if (mounted && _liveStatus != _LiveStatus.listening) {
          setState(() {
            _liveStatus = _LiveStatus.listening;
            _activeStreamingTurnId = '';
          });
        }
        break;
      case LiveServerEventType.asrSegment:
        // brief 第 9 节"禁止默认展示完整 ASR 转写文本"；这里只把片段
        // 记进 history 供下一次提交使用，UI 主区不显示。Debug 模式（
        // _kShowLegacyTextInputByDefault==true）下塞到 speech controller
        // 末尾，方便学生 / 演示者校对。
        final segment = (event.payload as LiveAsrSegmentPayload).text;
        if (segment.isEmpty) break;
        if (_kShowLegacyTextInputByDefault) {
          final base = _speechController.text;
          _speechController.text =
              base.isEmpty ? segment : '$base $segment';
        }
        break;
      case LiveServerEventType.thinking:
        if (mounted) {
          setState(() {
            _liveStatus = _LiveStatus.thinking;
          });
        }
        break;
      case LiveServerEventType.agentTurnStart:
        final p = event.payload as LiveAgentTurnStartPayload;
        final role = parseAgentRole(p.role);
        setState(() {
          _liveStatus = _LiveStatus.aiSpeaking;
          _activeStreamingTurnId = p.turnId;
          _turns.add(AgentTurn(
            turnId: p.turnId,
            role: role,
            displayName: p.displayName.isEmpty
                ? _defaultDisplayName(role)
                : p.displayName,
            text: '',
            highlightStepIds: p.highlightStepIds,
          ));
        });
        if (p.highlightStepIds.isNotEmpty) {
          _canvasController.setHighlight(p.highlightStepIds);
        }
        _scrollToBottomSoon();
        break;
      case LiveServerEventType.agentTurnDelta:
        final p = event.payload as LiveAgentTurnDeltaPayload;
        if (p.delta.isEmpty) break;
        // 替换 _turns 中匹配 turnId 的那条，把 text 追加 delta。
        for (var i = _turns.length - 1; i >= 0; i--) {
          if (_turns[i].turnId == p.turnId) {
            final prev = _turns[i];
            setState(() {
              _turns[i] = AgentTurn(
                turnId: prev.turnId,
                role: prev.role,
                displayName: prev.displayName,
                text: '${prev.text}${p.delta}',
                highlightStepIds: prev.highlightStepIds,
              );
            });
            break;
          }
        }
        break;
      case LiveServerEventType.agentTurnDone:
        final p = event.payload as LiveAgentTurnDonePayload;
        // 找到这条 turn，记录到 history 并触发 TTS。
        AgentTurn? doneTurn;
        for (final t in _turns) {
          if (t.turnId == p.turnId) {
            doneTurn = t;
            break;
          }
        }
        if (doneTurn != null) {
          _replayService.appendTurn(
            role: agentRoleWire(doneTurn.role),
            displayName: doneTurn.displayName,
            text: doneTurn.text,
          );
          _history.add(_agentTurnToHistory(doneTurn));
          if (_history.length > _maxHistoryItems) {
            _history.removeRange(
              0,
              _history.length - _maxHistoryItems,
            );
          }
          // 触发 TTS。失败由 LiveLectureService 写到 errors 流并显示为失败态。
          unawaited(_liveService.requestTts(
            doneTurn.text,
            role: agentRoleWire(doneTurn.role),
          ));
        }
        if (_activeStreamingTurnId == p.turnId) {
          _activeStreamingTurnId = '';
        }
        break;
      case LiveServerEventType.roundDone:
        final p = event.payload as LiveRoundDonePayload;
        setState(() {
          _round += 1;
          _lastResponseStatus = p.status;
          if (p.status == 'completed') {
            _status = _LectureStatus.finished;
            _turns.add(const AgentTurn(
              role: AgentRole.system,
              displayName: '系统',
              text: '这一题讲清楚了。可以点「下一题」继续，也可以点「再讲一遍」复盘。',
              highlightStepIds: [],
            ));
          } else {
            _status = _LectureStatus.awaiting;
          }
          // round_done 不一定立刻收到 listening；先切回 listening，
          // 后续如果再来一条 listening event 会幂等。
          _liveStatus = _LiveStatus.listening;
        });
        if (p.status == 'completed') {
          // 复用第六/八轮的本地落地逻辑。把"流式 turns"包成
          // LectureSubmitResponse 喂给 _persistCompletion，让小结卡 /
          // 回顾记录 / 进度仓库都被正确写入。
          final fakeResp = LectureSubmitResponse(
            questionId: _question.questionId,
            sectionId: widget.section.id,
            status: p.status,
            masteryDelta: p.masteryDelta,
            turns: List<AgentTurn>.unmodifiable(_turns
                .where((t) => t.role != AgentRole.system)
                .toList(growable: false)),
          );
          unawaited(_persistCompletion(fakeResp));
          unawaited(_replayService.finishAndUpload());
        }
        _scrollToBottomSoon();
        break;
      case LiveServerEventType.warning:
        // warning 只用于非致命协议提示；真实链路错误走 error。
        break;
      case LiveServerEventType.error:
        setState(() {
          _liveStatus = _LiveStatus.failed;
          _activeStreamingTurnId = '';
          _ttsPlaying = false;
          _liveFailureReason =
              (event.payload as LiveErrorPayload).message;
        });
        break;
      case LiveServerEventType.unknown:
        break;
    }
  }

  void _onLiveServiceError(String message) {
    if (!mounted) return;
    setState(() {
      _liveStatus = _LiveStatus.failed;
      _activeStreamingTurnId = '';
      _ttsPlaying = false;
      _liveFailureReason = message;
    });
  }

  void _onLiveConnection(LiveConnectionState state) {
    if (!mounted) return;
    switch (state) {
      case LiveConnectionState.connected:
        // _onStartLive 已经把状态切到 listening；这里幂等。
        break;
      case LiveConnectionState.disconnected:
        setState(() {
          _liveStatus = _LiveStatus.disconnected;
          _activeStreamingTurnId = '';
          _ttsPlaying = false;
        });
        unawaited(_audioService.stop());
        unawaited(_liveService.stopTts());
        break;
    }
  }

  void _onTtsState(TtsState state) {
    if (!mounted) return;
    setState(() {
      _ttsPlaying = state == TtsState.playing;
    });
  }

  /// 把后端 wire role 字符串映射回中文 displayName 兜底。
  String _defaultDisplayName(AgentRole role) {
    switch (role) {
      case AgentRole.xiaoming:
        return '小明';
      case AgentRole.daxiong:
        return '大雄';
      case AgentRole.classLeader:
      case AgentRole.monitor:
        return '班长';
      case AgentRole.teacher:
        return '李老师';
      case AgentRole.system:
        return '系统';
    }
  }

  AgentRole _lastNonSystemRole() {
    for (final turn in _turns.reversed) {
      if (turn.role != AgentRole.system) return turn.role;
    }
    return AgentRole.teacher;
  }

  String _interruptMessageFor(AgentRole role) {
    switch (role) {
      case AgentRole.xiaoming:
        return '没事，你继续说，我听着。';
      case AgentRole.daxiong:
        return '哦哦，你有新想法了？那我先不抢话。';
      case AgentRole.classLeader:
      case AgentRole.monitor:
        return '你先把自己的思路讲完整，我帮你记重点。';
      case AgentRole.teacher:
        return '你有新想法啦，慢慢讲，我先听你说。';
      case AgentRole.system:
        return '我先停下来听你讲。';
    }
  }

  /// 把 [_LiveStatus] 翻译成 [RealtimeAudioPanelState]：UI 层只关心
  /// 视觉状态，不关心"录音是否真的在跑"vs."WS 是否真的连上"这种细节。
  RealtimeAudioPanelState get _panelState {
    switch (_liveStatus) {
      case _LiveStatus.idle:
        return RealtimeAudioPanelState.idle;
      case _LiveStatus.connecting:
      case _LiveStatus.listening:
        return RealtimeAudioPanelState.listening;
      case _LiveStatus.paused:
        return RealtimeAudioPanelState.paused;
      case _LiveStatus.thinking:
        return RealtimeAudioPanelState.thinking;
      case _LiveStatus.aiSpeaking:
        return RealtimeAudioPanelState.aiSpeaking;
      case _LiveStatus.disconnected:
        return RealtimeAudioPanelState.disconnected;
      case _LiveStatus.permissionDenied:
        return RealtimeAudioPanelState.permissionDenied;
      case _LiveStatus.failed:
        return RealtimeAudioPanelState.failed;
    }
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
    final total = _questions.isEmpty ? 1 : _questions.length;
    final order = _questionIndex + 1;
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        // 第七轮：AppBar 标题同时点出小节与"第 N / M 题"，让学生即使
        // 滚到对话区底部也能看清自己当前在哪道题；切下一题时随题面同步。
        title: Text('${widget.section.label} · 第 $order / $total 题'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: AnimatedBuilder(
                // 第六轮：徽标既反映「本题第几轮」也反映「本节当前掌握度」。
                // ProgressRepository notify 时（completed 写盘成功）自动重建。
                animation: ProgressRepository.instance,
                builder: (context, _) {
                  final p = ProgressRepository.instance
                      .progressFor(widget.section.id);
                  return _MasteryBadge(round: _round, progress: p);
                },
              ),
            ),
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
          _QuestionCard(
            question: _question,
            order: _questionIndex + 1,
            total: _questions.isEmpty ? 1 : _questions.length,
          ),
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
          // 第六轮：completed 状态下展示「本题讲题小结」卡（替换第五轮的
          // 简单 banner），随后是「再讲一遍 / 下一题」两个对等动作。
          // 不自动清空画布，给学生留时间回看高亮。
          if (_status == _LectureStatus.finished &&
              _lastResponseStatus == 'completed') ...[
            const SizedBox(height: 12),
            _LectureSummaryCard(
              summary: _lastSummary,
              progress: _sectionProgressAfterCompletion,
              gained: _lastMasteryGain,
            ),
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
        Expanded(
          child: AnimatedBuilder(
            animation: UserCosmeticsPrefs.instance,
            builder: (context, _) => HandCanvas(
              controller: _canvasController,
              penStyle: UserCosmeticsPrefs.instance.penStyle,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 第九轮：白板下方默认展示实时音频面板（替换第四轮的文字输入区）。
        // 兜底情况下（_kShowLegacyTextInputByDefault=true 或 disconnected /
        // permissionDenied / failed）才再展示文字输入区作为白板-only 兜底
        // 提交的辅助。brief 第 9 节"默认不展示文字输入框，但允许白板-only
        // 兜底提交"。
        RealtimeAudioPanel(
          state: _panelState,
          onStart: _onStartLive,
          onStop: _onStopLive,
          onEndQuestion: _onEndLiveSession,
          onManualPause: _onManualPause,
          onFallbackSubmit: _onFallbackTextSubmit,
          canManualPause: _liveStatus == _LiveStatus.listening ||
              _liveStatus == _LiveStatus.paused,
          failureReason: _liveFailureReason,
        ),
        if (_debugOcr) ...[
          const SizedBox(height: 12),
          _buildDebugOcrPanel(),
        ],
        if (_kShowLegacyTextInputByDefault ||
            _liveStatus == _LiveStatus.disconnected ||
            _liveStatus == _LiveStatus.permissionDenied ||
            _liveStatus == _LiveStatus.failed) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: AnimatedBuilder(
                animation: _canvasController,
                builder: (context, _) => _buildSemanticInputsPanel(context),
              ),
            ),
          ),
        ],
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
                // 第九轮：原"提交讲解"按钮降级为兜底入口，仅当 disconnected /
                // permissionDenied / failed / 显式 fallback 模式下可见。
                if (_kShowLegacyTextInputByDefault ||
                    _liveStatus == _LiveStatus.disconnected ||
                    _liveStatus == _LiveStatus.permissionDenied ||
                    _liveStatus == _LiveStatus.failed)
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

  /// 实时面板的"用文字提交"入口。
  ///
  /// 当 WS / 麦克风 / 录音库出问题时，学生可以手动改用
  /// `/lecture/submit` 路径提交本题。此入口会**强制**展示底部文字
  /// 输入区（与 `_kShowLegacyTextInputByDefault` 等效），让学生
  /// 把口述写进去后点「提交讲解」。
  void _onFallbackTextSubmit() {
    if (_canvasController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先在白板上写一两行思路，再用文字提交。'),
        ),
      );
      return;
    }
    // 直接走原有 _onSubmit：它会根据当前白板 / 文字输入区做一次提交。
    unawaited(_onSubmit());
  }

  Widget _buildDebugOcrPanel() {
    return ValueListenableBuilder<List<OcrStepGuess>>(
      valueListenable: OcrService.debugGuesses,
      builder: (context, guesses, _) {
        return ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
          collapsedShape:
              const RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
          backgroundColor: AppPalette.surface,
          collapsedBackgroundColor: AppPalette.surface,
          title: const Text('DEBUG OCR / HWR'),
          subtitle: Text(guesses.isEmpty ? '暂无识别结果' : '${guesses.length} 个 step'),
          children: guesses.isEmpty
              ? const [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('写字后等待 480ms 或提交讲解即可看到 source/confidence/mode。'),
                  ),
                ]
              : guesses
                  .map(
                    (g) => ListTile(
                      dense: true,
                      title: Text('${g.stepId} · ${g.source} · ${g.mode}'),
                      subtitle: Text(
                        '${g.confidence.toStringAsFixed(2)} · ${g.latex.isEmpty ? g.plainText : g.latex}',
                      ),
                    ),
                  )
                  .toList(growable: false),
        );
      },
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

/// 「本题讲题小结」卡片：第六轮替换第五轮的 `_CompletionBanner`。
///
/// 设计原则：
///   * 学习反馈基调，不要游戏化（无奖杯 / 烟花 / 高饱和渐变）。
///   * 标题「本题讲清楚了」复用第五轮的语境；正文是
///     `lastSummary`（教师 / AI 收束话），用 [FormulaText] 渲染保证
///     `\sqrt{}` 一类 token 不变乱码。
///   * 末行展示「本节掌握度 +X，当前 N/100」，掌握度变化只在 [gained] > 0
///     时显示加号；首次落地 progress 失败时 progress 为 null，则隐藏整行。
class _LectureSummaryCard extends StatelessWidget {
  const _LectureSummaryCard({
    required this.summary,
    required this.progress,
    required this.gained,
  });

  final String summary;
  final SectionProgress? progress;
  final int gained;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSummary = summary.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppPalette.primaryAccent.withValues(alpha: 0.08),
        borderRadius: AppRadius.cardR,
        border: Border.all(
          color: AppPalette.primaryAccent.withValues(alpha: 0.32),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.menu_book_outlined,
                size: 20,
                color: AppPalette.primaryAccent,
              ),
              const SizedBox(width: 8),
              Text(
                '本题讲清楚了',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppPalette.primaryAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (hasSummary) ...[
            const SizedBox(height: 10),
            Text(
              '本轮小结',
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            FormulaText(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textPrimary,
                height: 1.5,
              ),
              formulaStyle: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.primary,
                fontWeight: FontWeight.w700,
                height: 1.5,
              ),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 12),
            _MasteryDeltaRow(progress: progress!, gained: gained),
          ],
          const SizedBox(height: 6),
          Text(
            '不自动清空画板，可以回看高亮再点「下一题」或「再讲一遍」。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 完成态卡片底部的「本节掌握度 +X，当前 N/100」一行 + 细进度条。
class _MasteryDeltaRow extends StatelessWidget {
  const _MasteryDeltaRow({required this.progress, required this.gained});

  final SectionProgress progress;
  final int gained;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = progress.masteryScore.clamp(0, 100);
    final widthFactor = score / 100.0;
    final gainLabel = gained > 0 ? '+$gained' : '已封顶';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.insights_outlined,
              size: 18,
              color: AppPalette.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '本节掌握度 $gainLabel · 当前 $score/100',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '已完成 ${progress.completedRounds} 轮',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: Stack(
              children: [
                Container(color: AppPalette.primary.withValues(alpha: 0.12)),
                FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(color: AppPalette.primary),
                ),
              ],
            ),
          ),
        ),
      ],
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
  const _QuestionCard({
    required this.question,
    required this.order,
    required this.total,
  });

  final LectureQuestion question;

  /// 当前题在本节的序号（从 1 开始）。
  final int order;

  /// 本节总题数。
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final difficultyLabel = MockLectureRepository.instance
        .difficultyLabel(question.difficulty);
    // 第七轮：标签数量已由 Mock 题库控制在 1-3 个；此处再做一次硬上限
    // 防御未来题库走样，避免题面卡片被 chip 撑成 N 行挤压手写板主区。
    final tags = question.tags.take(3).toList(growable: false);
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
              Expanded(
                child: Text(
                  '${question.sectionLabel} · 第 $order / $total 题',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: AppPalette.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 难度 chip + 知识标签 chip。Wrap 让窄屏自动换行，不会挤压手写板。
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _DifficultyChip(label: difficultyLabel, level: question.difficulty),
              for (final t in tags) _TagChip(label: t),
            ],
          ),
          const SizedBox(height: 10),
          FormulaText(
            question.prompt,
            style: theme.textTheme.bodyLarge,
            formulaStyle: theme.textTheme.bodyLarge?.copyWith(
              color: AppPalette.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (question.image != null) ...[
            const SizedBox(height: 12),
            _QuestionImage(image: question.image!),
          ],
          const SizedBox(height: 8),
          FormulaText(
            question.hint,
            style: theme.textTheme.bodySmall,
            formulaStyle: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.primaryAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionImage extends StatelessWidget {
  const _QuestionImage({required this.image});

  final QuestionImage image;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: image.alt,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppPalette.surface,
          borderRadius: AppRadius.cardR,
          border: Border.all(color: AppPalette.outline),
        ),
        child: SvgPicture.asset(
          image.asset,
          height: 150,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

/// 难度 chip：基础（湖青）/ 巩固（深蓝）/ 挑战（警示红）。
///
/// 配色范围严格限定在 `AppPalette` 已有的几个柔和色，**不**引入红橙渐变
/// 等"游戏化徽章"风（见 `MOBILE_STYLE.md` 第 1 节远离清单）。
class _DifficultyChip extends StatelessWidget {
  const _DifficultyChip({required this.label, required this.level});

  final String label;
  final int level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      3 => AppPalette.error,
      2 => AppPalette.primary,
      _ => AppPalette.primaryAccent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 知识标签 chip：纯文本、柔和湖青描边，仅前端展示用。
///
/// 与 `home_page.dart` 里的 `_Tag` 风格一致，但本控件刻意**不**复用 ——
/// 那个是 home page 私有的，跨文件引用会变成隐性公共契约，得不偿失。
class _TagChip extends StatelessWidget {
  const _TagChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const color = AppPalette.primaryAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
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
  const _MasteryBadge({required this.round, this.progress});

  final int round;
  final SectionProgress? progress;

  @override
  Widget build(BuildContext context) {
    // 优先用「本节累计掌握度」表达，让学生看到跨题持续的学习收益；
    // 没有任何完成记录时退回「理解中 / 已完成 N 轮」的回合表达。
    final p = progress;
    if (p != null && p.hasAnyCompletion) {
      const color = AppPalette.primaryAccent;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(
          '本节 ${p.masteryScore}/100 · 已完成 ${p.completedRounds} 轮',
          style: const TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final label = round == 0 ? '理解中' : '本轮第 $round 次提交';
    final color =
        round == 0 ? AppPalette.textSecondary : AppPalette.primaryAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
