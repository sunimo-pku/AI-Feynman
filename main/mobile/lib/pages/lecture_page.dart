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
import '../services/peer_reason_playback_service.dart';
import '../services/progress_repository.dart';
import '../services/replay_service.dart';
import '../services/review_repository.dart';
import '../services/user_cosmetics_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/hand_canvas.dart';
import '../widgets/lecture_orb_button.dart';
import '../widgets/lecture_peer_rail.dart';
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
    this.questionOverride,
    this.assignmentId,
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

  /// 家长布置作业：覆盖题库题目（自定义题面或指定 questionId）。
  final LectureQuestion? questionOverride;

  /// 关联的作业 id，用于打开态标记（可选）。
  final String? assignmentId;

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
///   * `paused`：录音服务检测到静音；当前产品不再用它触发追问；
///   * `thinking`：学生点「讲题结束」后，已经发了 `pause_detected`，等 AI 思考；
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
  final PeerReasonPlaybackService _reasonPlayback = PeerReasonPlaybackService();

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

  /// 本轮三名同伴的听懂状态（P1）。
  List<PeerAssessment> _peerAssessments = const [];

  /// 李老师「需要提示」请求进行中。
  bool _hintLoading = false;

  /// 右侧头像轨：当前展开全文追问气泡的角色（再点一次收起）。
  AgentRole? _expandedPeerBubble;

  /// 讲题白板工具：画笔 / 橡皮擦。
  CanvasDrawMode _canvasDrawMode = CanvasDrawMode.pen;

  static const int _maxHistoryItems = 6;

  // —— 第九轮：实时双工讲题相关状态 ————————————————————————————————————
  final AudioStreamService _audioService = AudioStreamService();
  final LiveLectureService _liveService = LiveLectureService();
  final ReplayService _replayService = ReplayService();

  _LiveStatus _liveStatus = _LiveStatus.idle;
  String? _liveFailureReason;

  /// 当前正在被流式增量的 AI turn id；空字符串表示当前没有未完成 turn。
  String _activeStreamingTurnId = '';
  Timer? _inkSnapshotDebounce;
  Timer? _stuckHintTimer;
  Timer? _wrapUpTimer;

  /// thinking 状态的「看门狗」：发出 pause_detected 后启动，超时仍未收到
  /// [agentTurnStart] / [roundDone] / [error] / [warning] 事件就主动把状态
  /// 切回 listening + 显示友好提示，避免 UI 永远卡在「AI 正在想问题」。
  ///
  /// 后端真实时间预算：
  ///   * `lecture_agent_stream` 流式首 token timeout=2s
  ///   * `lecture_agent` 非流式备用 timeout=6s
  ///   * 知识检索 + ASR flush + 网络往返 ≤ 1s
  /// 实测端到端 1-3s 出第一条 agent_turn_start。
  ///
  /// 9 秒看门狗 = 后端最坏路径 (2s 流式失败 + 6s 备用) + 网络余量 1s。
  /// 第十二轮初版给到 14s 太保守了：用户反馈体感像"AI 死机"，且实际
  /// 上 8s 没回基本可以判定真挂了。
  ///
  /// 触发场景（罕见，但是必须有兜底）：
  ///   * 后端发了 warning + listening，但 listening 在网络层丢失；
  ///   * LLM 调用挂在 connect / yield 期间，pause_detected 后没有下行；
  ///   * WS 在 pause_detected 之后立刻断（NAT 超时 / 服务端重启），
  ///     onError / onDone 已经把 _isConnected 切 false，但 UI 还在 thinking。
  Timer? _thinkingWatchdogTimer;
  static const Duration _thinkingWatchdogTimeout = Duration(seconds: 9);

  late final StreamSubscription _liveEventsSub;
  late final StreamSubscription _liveErrorsSub;
  late final StreamSubscription _liveConnSub;
  late final StreamSubscription _audioChunksSub;
  late final StreamSubscription _audioPausesSub;
  late final StreamSubscription _audioVoiceSub;
  late final StreamSubscription _audioStatusSub;

  @override
  void initState() {
    super.initState();
    final repo = MockLectureRepository.instance;
    if (widget.questionOverride != null) {
      _questions = [widget.questionOverride!];
      _questionIndex = 0;
      _question = widget.questionOverride!;
    } else {
      // 第七轮：题库一次性加载，后续翻题只动 [_questionIndex] —— 仓库本身
      // 是不可变 const list，多次调用 questionsForSection 也安全，但保留
      // 一份快照能让讲题页所有 sub-widget 看到的题序保持一致。
      _questions = repo.questionsForSection(widget.section.id);
      // 第八轮：优先用 widget.initialQuestionId 定位（来自回顾页「再讲这题」）,
      // 命中失败时回落 widget.initialQuestionIndex，再不行回落第 1 题。
      _questionIndex = _resolveInitialQuestionIndex();
      if (widget.initialQuestionId == null &&
          widget.initialQuestionIndex == null) {
        _questionIndex = _recommendedInitialQuestionIndex();
      }
      _question =
          _questions.isEmpty
              ? repo.questionForSection(widget.section.id)
              : _questions[_questionIndex];
    }
    _turns.add(_introTurn());
    _canvasController.addListener(_onCanvasChanged);
    _reasonPlayback.addListener(_onReasonPlaybackChanged);
    _wireLiveServices();
    UserCosmeticsPrefs.instance.load();
    unawaited(_ensureAssetBankLoaded());
  }

  /// 题库 JSON 在 [StudentMainShell] 里异步加载；若进讲题页时尚未完成，
  /// 会先拿到 stub 题（无配图）。加载完成后按 questionId 刷新本题列表。
  Future<void> _ensureAssetBankLoaded() async {
    final repo = MockLectureRepository.instance;
    await repo.loadAssetBank();
    if (!mounted || widget.questionOverride != null) return;
    final fresh = repo.questionsForSection(widget.section.id);
    if (fresh.isEmpty) return;
    var idx = _questionIndex % fresh.length;
    for (var i = 0; i < fresh.length; i++) {
      if (fresh[i].questionId == _question.questionId) {
        idx = i;
        break;
      }
    }
    setState(() {
      _questions = fresh;
      _questionIndex = idx;
      _question = fresh[idx];
    });
  }

  /// 把 [_audioService] 与 [_liveService] 的所有事件流串到 setState 上。
  ///
  /// 这些 subscription 在 [dispose] 里统一 cancel，避免 leak。
  void _wireLiveServices() {
    _liveEventsSub = _liveService.events.listen(_onLiveEvent);
    _liveErrorsSub = _liveService.errors.listen(_onLiveServiceError);
    _liveConnSub = _liveService.connectionState.listen(_onLiveConnection);
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
    _reasonPlayback.removeListener(_onReasonPlaybackChanged);
    _reasonPlayback.dispose();
    unawaited(_replayService.finishAndUpload());
    _replayService.close();
    // 第九轮：实时讲题资源全部释放。subscription cancel 顺序不重要，但
    // _liveService / _audioService 的 dispose 必须 await 才能真正关闭
    // WS 句柄；这里走 unawaited，因为 dispose 不能是 async。
    _inkSnapshotDebounce?.cancel();
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
    _thinkingWatchdogTimer?.cancel();
    unawaited(_liveEventsSub.cancel());
    unawaited(_liveErrorsSub.cancel());
    unawaited(_liveConnSub.cancel());
    unawaited(_audioChunksSub.cancel());
    unawaited(_audioPausesSub.cancel());
    unawaited(_audioVoiceSub.cancel());
    unawaited(_audioStatusSub.cancel());
    unawaited(_audioService.dispose());
    unawaited(_liveService.dispose());
    super.dispose();
  }

  void _onReasonPlaybackChanged() {
    if (mounted) setState(() {});
  }

  /// 监听手写板变化：
  ///   * 画板被清空（`isEmpty`）时把所有步骤说明输入框文本归零，
  ///     而不是销毁 controller（销毁会让 [TextField] state 报错）。
  ///   * 出现新 stepId 时不在这里建 controller，留给 [_ensureStepControllers]
  ///     在 build 阶段 lazy 创建，避免在 listener 里 setState 抖动。
  void _onCanvasChanged() {
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
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
    // 白板任何更新都 debounce 500ms 后给后端发一次 snapshot。当前体验
    // 改为「微信语音」式手动收束，落笔不再打断 AI 播报。
    _scheduleInkSnapshot();
  }

  /// 第十二轮：调用方传 [immediate=true] 可以**跳过 480ms debounce** 直接
  /// 发 ink_snapshot。用在：
  ///   * `_onStartLive` 连接成功后立即把白板状态同步给新 session，避免
  ///     学生因为「换题 / 重新连接 → 新 ws + 新 session_start」导致后端
  ///     latest_steps 重新清零，然后秒按「讲题结束」时撞 no_steps_yet。
  ///   * 任何其它「立刻让后端拿到当前白板」的场景。
  void _scheduleInkSnapshot({bool immediate = false}) {
    _inkSnapshotDebounce?.cancel();
    if (immediate) {
      unawaited(_pushInkSnapshotNow());
      return;
    }
    _inkSnapshotDebounce = Timer(const Duration(milliseconds: 480), () async {
      await _pushInkSnapshotNow();
    });
  }

  Future<void> _pushInkSnapshotNow() async {
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
    if (_status != _LectureStatus.awaiting && _status != _LectureStatus.error) {
      return null;
    }
    for (final t in _turns.reversed) {
      switch (t.role) {
        case AgentRole.xiaoming:
        case AgentRole.daxiong:
        case AgentRole.classLeader:
        case AgentRole.monitor:
          return t;
        case AgentRole.teacher:
          // 李老师提示不要求学生「回答」，不算待回应追问。
          continue;
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
    final levelLabel = MockLectureRepository.instance.difficultyLabel(
      _question.difficulty,
    );
    return AgentTurn(
      role: AgentRole.system,
      displayName: '系统',
      text:
          '欢迎来到「${_question.sectionLabel}」讲题课，这是本节的第 $order / $total 题（$levelLabel）。'
          '请你在右侧手写板上写出解题步骤，边写边想；'
          '写完后点「开始讲题」或「提交讲解」，小明、大雄和班长会各自判断有没有听懂。'
          '卡住时可点「需要提示」，李老师才会发言。',
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
    return List.unmodifiable(base.sublist(base.length - _maxHistoryItems));
  }

  LectureSubmitRequest _buildRequest() {
    final stepInfos = _canvasController.collectStepInfos();
    final steps = stepInfos
        .map((info) {
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
        })
        .toList(growable: false);

    // 第五轮：构造请求时**临时**生成本轮 student 历史项（基于当前输入快照）。
    // 这条记录不立刻 push 进 [_history]；只有请求成功后才会和 AI turns 一起
    // 落库 —— 这样失败重试 [_lastFailedRequest] 时，不会重复追加同一条
    // student 历史，避免学生看到「请求失败 → 历史里多一条自己 → 重试 →
    // 历史又多一条自己」的鬼畜效果。
    final speech = _speechController.text.trim();
    final pendingStudentItem = LectureHistoryItem(
      role: 'student',
      displayName: '我',
      text: _composeStudentHistoryText(speech: speech, stepInfos: stepInfos),
      highlightStepIds: stepInfos
          .map((info) => info.stepId)
          .toList(growable: false),
    );

    final historyForRequest = _historyTail([..._history, pendingStudentItem]);

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画板还没有内容，先把你的思路写一两行再提交吧。')));
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

  String _assessmentRoundSummary(List<PeerAssessment> assessments) {
    final understood =
        assessments.where((a) => a.understood).map((a) => a.displayName).toList();
    final confused =
        assessments.where((a) => !a.understood).map((a) => a.displayName).toList();
    if (confused.isEmpty) {
      return '小明、大雄、班长都听懂了！';
    }
    if (understood.isEmpty) {
      return '小明、大雄、班长都还没完全听懂，请看下面的理由再讲一轮。';
    }
    return '${understood.join('、')}听懂了，${confused.join('、')}还没听懂，请看理由再讲一轮。';
  }

  /// P1/P3：文字提交与实时语音共用 —— 把三人评估结果落到 UI / history / 播放队列。
  void _applyPeerAssessmentRound({
    required List<PeerAssessment> assessments,
    required bool allUnderstood,
    required String status,
    required int masteryDelta,
    AgentTurn? teacherSummary,
    LectureHistoryItem? committedStudent,
    bool omitTeacherTurn = false,
  }) {
    _peerAssessments = assessments;
    _lastResponseStatus = status;

    _turns.add(
      AgentTurn(
        role: AgentRole.system,
        displayName: '系统',
        text: _assessmentRoundSummary(assessments),
        highlightStepIds: const [],
      ),
    );

    if (allUnderstood) {
      if (teacherSummary != null && !omitTeacherTurn) {
        _turns.add(teacherSummary);
        _lastSummary = teacherSummary.text.trim();
      } else if (teacherSummary != null) {
        _lastSummary = teacherSummary.text.trim();
      } else {
        _lastSummary = _composeCompletionSummary(const []);
      }
      _turns.add(
        const AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '三名同伴都听懂了。可以点「下一题」继续，也可以点「再讲一遍」复盘。',
          highlightStepIds: [],
        ),
      );
      _status = _LectureStatus.finished;
      unawaited(_reasonPlayback.stop());
      _reasonPlayback.clearQueue();
    } else {
      for (final a in assessments.where((x) => !x.understood)) {
        _turns.add(
          a.toReasonTurn(turnId: 'reason_${agentRoleWire(a.role)}'),
        );
      }
      _status = _LectureStatus.awaiting;
      _reasonPlayback.setQueue(assessments);
    }

    if (committedStudent != null && committedStudent.role == 'student') {
      _history.add(committedStudent);
    }
    for (final a in assessments) {
      _history.add(a.toHistoryItem());
    }
    if (teacherSummary != null) {
      _history.add(_agentTurnToHistory(teacherSummary));
    }
    if (_history.length > _maxHistoryItems) {
      _history.removeRange(0, _history.length - _maxHistoryItems);
    }

    final highlightIds = assessments
        .where((a) => !a.understood)
        .expand((a) => a.highlightStepIds)
        .toSet();
    if (highlightIds.isNotEmpty) {
      _canvasController.setHighlight(highlightIds);
    } else if (teacherSummary != null &&
        teacherSummary.highlightStepIds.isNotEmpty) {
      _canvasController.setHighlight(teacherSummary.highlightStepIds);
    }

    if (allUnderstood) {
      unawaited(
        _persistCompletion(
          LectureSubmitResponse(
            questionId: _question.questionId,
            sectionId: widget.section.id,
            status: status,
            masteryDelta: masteryDelta,
            allUnderstood: true,
            assessments: assessments,
            teacherSummary: teacherSummary,
          ),
        ),
      );
    }
  }

  LectureHistoryItem? _buildLiveStudentHistoryItem() {
    final stepInfos = _canvasController.collectStepInfos();
    final speech = _speechController.text.trim();
    final text = _composeStudentHistoryText(
      speech: speech,
      stepInfos: stepInfos,
    );
    if (text == '（学生本轮没有补充任何文字说明）' &&
        stepInfos.every((s) => s.strokeCount <= 0)) {
      return null;
    }
    return LectureHistoryItem(
      role: 'student',
      displayName: '我',
      text: text,
      highlightStepIds: stepInfos.map((s) => s.stepId).toList(growable: false),
    );
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
        _turns.add(
          AgentTurn(
            role: AgentRole.system,
            displayName: '系统',
            text: '已收到第 $_round 轮讲解，小明、大雄、班长正在听……',
            highlightStepIds: const [],
          ),
        );
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
      final committedStudent =
          request.history.isNotEmpty ? request.history.last : null;

      setState(() {
        _errorMessage = null;
        _lastFailedRequest = null;
        _applyPeerAssessmentRound(
          assessments: response.assessments,
          allUnderstood: response.allUnderstood,
          status: response.status,
          masteryDelta: response.masteryDelta,
          teacherSummary: response.teacherSummary,
          committedStudent: committedStudent,
        );
      });
      _scrollToBottomSoon();
    } on LectureApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _LectureStatus.error;
        _errorMessage = e.userMessage;
        _lastFailedRequest = request;
        if (!retry &&
            _turns.isNotEmpty &&
            _turns.last.role == AgentRole.system) {
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
        if (!retry &&
            _turns.isNotEmpty &&
            _turns.last.role == AgentRole.system) {
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
    final summary =
        response.teacherSummary?.text.trim() ??
        _composeCompletionSummary(
          response.teacherSummary != null
              ? [response.teacherSummary!]
              : const [],
        );
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
    final highlightTurns = <AgentTurn>[
      ...response.assessments
          .where((a) => !a.understood)
          .map((a) => a.toReasonTurn()),
      if (response.teacherSummary != null) response.teacherSummary!,
    ];
    final highlights = _composeAgentHighlights(highlightTurns);
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
    String? findPeerAi(Iterable<AgentTurn> turns) {
      for (final t in turns.toList().reversed) {
        switch (t.role) {
          case AgentRole.xiaoming:
          case AgentRole.daxiong:
          case AgentRole.classLeader:
          case AgentRole.monitor:
            if (t.text.trim().isNotEmpty) return t.text.trim();
          case AgentRole.teacher:
          case AgentRole.system:
            continue;
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

    final peerInLatest = findPeerAi(latestTurns);
    if (peerInLatest != null) return peerInLatest;
    final aiInLatest = findAnyAi(latestTurns);
    if (aiInLatest != null) return aiInLatest;

    final peerInAll = findPeerAi(_turns);
    if (peerInAll != null) return peerInAll;
    final aiInAll = findAnyAi(_turns);
    if (aiInAll != null) return aiInAll;

    return '本题已完成一轮讲解，建议回看高亮步骤，总结这一步为什么成立。';
  }

  Future<void> _onRequestHint() async {
    if (_hintLoading || _status == _LectureStatus.submitting) {
      return;
    }
    if (_liveStatus == _LiveStatus.thinking) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('同伴正在思考，请稍候再点「需要提示」。')),
      );
      return;
    }

    if (_liveService.isConnected) {
      if (_liveService.sessionId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先点「开始讲题」，再向李老师要提示。')),
        );
        return;
      }
      setState(() => _hintLoading = true);
      // 必须先同步 ink_snapshot，否则后端 latest_steps 为空会直接 no_steps_yet。
      await _pushInkSnapshotNow();
      if (!mounted) return;
      _liveService.sendRequestHint();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已请李老师帮忙，请看右侧李老师头像旁的提示。'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _hintLoading = true;
      _turns.add(
        const AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '已向李老师请求提示……',
          highlightStepIds: [],
        ),
      );
    });
    _scrollToBottomSoon();

    try {
      final request = await _lectureService.enrichWithOcr(
        _buildRequest(),
        referenceSteps: _question.referenceSteps,
      );
      final response = await _lectureService.requestHint(request);
      if (!mounted) return;
      setState(() {
        _hintLoading = false;
        if (_turns.isNotEmpty && _turns.last.role == AgentRole.system) {
          _turns.removeLast();
        }
        _turns.add(response.turn);
        if (response.turn.role == AgentRole.teacher) {
          _expandedPeerBubble = AgentRole.teacher;
        }
        _history.add(_agentTurnToHistory(response.turn));
        if (_history.length > _maxHistoryItems) {
          _history.removeRange(0, _history.length - _maxHistoryItems);
        }
        if (_status == _LectureStatus.idle && _round > 0) {
          _status = _LectureStatus.awaiting;
        }
      });
      if (response.turn.highlightStepIds.isNotEmpty) {
        _canvasController.setHighlight(response.turn.highlightStepIds);
      }
      if (response.turn.role == AgentRole.teacher && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('李老师的提示在右侧头像旁，可点击展开全文。'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      _scrollToBottomSoon();
    } on LectureApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _hintLoading = false;
        if (_turns.isNotEmpty && _turns.last.role == AgentRole.system) {
          _turns.removeLast();
        }
        _errorMessage = e.userMessage;
        if (_round > 0) {
          _status = _LectureStatus.error;
        }
      });
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hintLoading = false;
        if (_turns.isNotEmpty && _turns.last.role == AgentRole.system) {
          _turns.removeLast();
        }
        _errorMessage = '请求提示失败：$e';
        if (_round > 0) {
          _status = _LectureStatus.error;
        }
      });
      _scrollToBottomSoon();
    }
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
    _peerAssessments = const [];
    _expandedPeerBubble = null;
    _canvasDrawMode = CanvasDrawMode.pen;
    unawaited(_reasonPlayback.stop());
    _reasonPlayback.clearQueue();
    _cancelThinkingWatchdog();
  }

  /// 第七轮：「下一题」=切到本节题库的下一道题。索引循环（第 3 题点下一题
  /// 回到第 1 题），同时清空所有临时态、重置 intro 气泡、引用新题面。
  ///
  /// 仅在本轮 `completed`（三名同伴都听懂）后允许切题；`awaiting` 时必须
  /// 先根据右侧追问再讲，不能跳过。
  ///
  /// 提交失败 / 错误重试时**不**走这里，仍保留输入（见 `_sendRequest` 错误分支）。
  void _onContinue() {
    if (_status != _LectureStatus.finished ||
        _lastResponseStatus != 'completed') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '还有同伴没听懂，请根据右侧追问再讲一轮；三名同伴都听懂后才能「下一题」。',
          ),
        ),
      );
      return;
    }
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
        ..add(
          const AgentTurn(
            role: AgentRole.system,
            displayName: '系统',
            text: '好，再讲一遍。这次你可以试着用更精炼的语言总结，每一步都说清「为什么这样做」。',
            highlightStepIds: [],
          ),
        );
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
    if (_liveService.isConnected) {
      final audioStarted = await _audioService.start();
      if (!mounted) return;
      if (!audioStarted) {
        final next =
            _audioService.status == AudioStreamStatus.permissionDenied
                ? _LiveStatus.permissionDenied
                : _LiveStatus.failed;
        setState(() {
          _liveStatus = next;
          _liveFailureReason = _audioService.failureReason ?? '录音不可用';
        });
        return;
      }
      _scheduleInkSnapshot(immediate: true);
      setState(() {
        _liveStatus = _LiveStatus.listening;
      });
      return;
    }
    setState(() {
      _liveStatus = _LiveStatus.connecting;
      _liveFailureReason = null;
    });
    final sessionId =
        'sess-${DateTime.now().millisecondsSinceEpoch}-'
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
      // 录音失败：保留 WS 让学生还能补写白板后重试，但状态切到失败态。
      final next =
          _audioService.status == AudioStreamStatus.permissionDenied
              ? _LiveStatus.permissionDenied
              : _LiveStatus.failed;
      setState(() {
        _liveStatus = next;
        _liveFailureReason = _audioService.failureReason ?? '录音不可用';
      });
      return;
    }
    // 启动成功后立刻把当前白板 snapshot 发出去（**跳过 debounce**），让后端
    // 在第一时间知道「学生目前有几步、笔画数」，避免学生在 480ms 内立即
    // 点「讲题结束」时新 session 的 latest_steps 还是空、撞 no_steps_yet。
    _scheduleInkSnapshot(immediate: true);
    setState(() {
      _liveStatus = _LiveStatus.listening;
    });
  }

  /// 「讲题结束」按钮：手动触发 AI 追问。
  ///
  /// 当前实时讲题改成类似微信群聊发语音：学生点「开始讲题」后持续录音，
  /// 不根据停顿/间隔自动判断讲完；只有学生明确点「讲题结束」才发
  /// pause_detected 进入 LLM 追问。
  void _onManualPause() {
    if (!_liveService.isConnected) return;
    _wrapUpTimer?.cancel();
    // 像发语音一样，学生点结束后立即停掉本段录音；AI 追问完成后再让
    // 学生手动开始下一段。
    unawaited(_audioService.stop());
    _liveService.sendPauseDetected(silenceMs: 0);
    _armThinkingWatchdog();
    setState(() {
      _round += 1;
      _turns.add(
        AgentTurn(
          role: AgentRole.system,
          displayName: '系统',
          text: '已收到第 $_round 轮讲解，小明、大雄、班长正在听……',
          highlightStepIds: const [],
        ),
      );
      _liveStatus = _LiveStatus.thinking;
    });
    _scrollToBottomSoon();
  }

  /// 启动 thinking 看门狗。重复调用幂等：每次调用都会 cancel 旧定时器。
  ///
  /// 看门狗超时后做的事：
  ///   * 切回 idle（保留 WS / 已识别 ASR，录音段已在「讲题结束」时停止）；
  ///   * 设一句 `_liveFailureReason` 友好提示，不切到 failed 态以免
  ///     学生觉得整次会话挂了；
  ///   * 不主动断 WS，因为后端可能还在生成、只是慢；如果 WS 真的断了，
  ///     `_onLiveConnection(disconnected)` 会单独把状态切到 disconnected。
  void _armThinkingWatchdog() {
    _thinkingWatchdogTimer?.cancel();
    _thinkingWatchdogTimer = Timer(_thinkingWatchdogTimeout, () {
      if (!mounted) return;
      if (_liveStatus != _LiveStatus.thinking) return;
      setState(() {
        _liveStatus = _LiveStatus.idle;
        _liveFailureReason = '后端暂时没回，请再讲两句或重新点「讲题结束」';
      });
    });
  }

  void _cancelThinkingWatchdog() {
    _thinkingWatchdogTimer?.cancel();
    _thinkingWatchdogTimer = null;
  }

  /// 「暂停倾听」按钮：thinking 阶段允许学生取消本轮，回到 idle 重写白板。
  void _onStopLive() {
    _cancelThinkingWatchdog();
    unawaited(_audioService.stop());
    unawaited(_liveService.stopTts());
    setState(() {
      _liveStatus = _LiveStatus.idle;
    });
  }

  /// 「结束本题」/「session_end」入口：关闭录音 + WS 会话，回到可重新讲题状态。
  Future<void> _onEndLiveSession() async {
    _inkSnapshotDebounce?.cancel();
    _cancelThinkingWatchdog();
    await _audioService.stop();
    await _liveService.endSession();
    await _liveService.stopTts();
    if (!mounted) return;
    setState(() {
      _liveStatus = _LiveStatus.idle;
      _activeStreamingTurnId = '';
    });
  }

  void _onAudioChunk(Uint8List data) {
    if (data.isEmpty) return;
    if (!_liveService.isConnected) return;
    _liveService.sendAudioBytes(data);
    _replayService.appendAudioChunk(base64Encode(data));
  }

  /// 收到 audio_service 的自然停顿信号。
  ///
  /// 产品体验已改为「学生手动点讲题结束」：停顿只取消旧的延迟任务，不再
  /// 触发 LLM，不再切到「AI 正在想问题」。
  void _onAudioPause(int silenceMs) {
    _stuckHintTimer?.cancel();
    _wrapUpTimer?.cancel();
  }

  void _onAudioVoice(bool active) {
    if (!_liveService.isConnected) return;
    if (active) {
      _stuckHintTimer?.cancel();
      _wrapUpTimer?.cancel();
    }
    if (active && _liveStatus == _LiveStatus.paused) {
      setState(() {
        _liveStatus = _LiveStatus.listening;
      });
    }
  }

  // 第九轮加过的 _showStuckHintIfStillPaused 通用文案插入逻辑在第十二轮
  // 被彻底删除：跨章节弹"卡住了..."模板严重出戏。当前语音体验也不再
  // 做静音后追问；如果未来想恢复"卡住"体感，要走学生显式按钮或后端
  // LLM，而不是前端写死。

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
        // 当前体验不再根据停顿自动触发或改变面板状态；学生自己点
        // 「讲题结束」才把这一段语音交给 AI。
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

  void _onLiveEvent(LiveServerEvent event) {
    switch (event.type) {
      case LiveServerEventType.listening:
        if (mounted) {
          setState(() {
            _activeStreamingTurnId = '';
            final isRecording =
                _audioService.status == AudioStreamStatus.listening ||
                _audioService.status == AudioStreamStatus.paused;
            _liveStatus =
                isRecording ? _LiveStatus.listening : _LiveStatus.idle;
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
          _speechController.text = base.isEmpty ? segment : '$base $segment';
        }
        break;
      case LiveServerEventType.thinking:
        // 后端 thinking 是「LLM 调用确认开始」的信号，看门狗在收到第一条
        // turn_start 之前不能解除（thinking 只表示后端进入了 LLM 调用阶段，
        // 真正卡死往往发生在 thinking → turn_start 之间）。这里不取消看门狗。
        if (mounted) {
          setState(() {
            _liveStatus = _LiveStatus.thinking;
          });
        }
        break;
      case LiveServerEventType.agentTurnStart:
        // 后端开始流式吐 turn 内容，确认 LLM 真的在产出 → 取消看门狗。
        _cancelThinkingWatchdog();
        final p = event.payload as LiveAgentTurnStartPayload;
        final role = parseAgentRole(p.role);
        setState(() {
          _liveStatus = _LiveStatus.aiSpeaking;
          _activeStreamingTurnId = p.turnId;
          if (role == AgentRole.teacher) {
            _hintLoading = false;
            _expandedPeerBubble = AgentRole.teacher;
          }
          _turns.add(
            AgentTurn(
              turnId: p.turnId,
              role: role,
              displayName:
                  p.displayName.isEmpty
                      ? _defaultDisplayName(role)
                      : p.displayName,
              text: '',
              highlightStepIds: p.highlightStepIds,
            ),
          );
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
          if (doneTurn.role == AgentRole.teacher) {
            if (mounted) {
              setState(() => _hintLoading = false);
            }
          }
          _replayService.appendTurn(
            role: agentRoleWire(doneTurn.role),
            displayName: doneTurn.displayName,
            text: doneTurn.text,
          );
          _history.add(_agentTurnToHistory(doneTurn));
          if (_history.length > _maxHistoryItems) {
            _history.removeRange(0, _history.length - _maxHistoryItems);
          }
          // 第十二轮第三轮：流式 TTS 优先。LLM 流式 delta 在后端逐句切句、
          // 边合成边推 `agent_tts_chunk`，前端 LiveLectureService 已经按
          // 队列播过了。这里如果再调一次整段 requestTts → 同一段话播两遍。
          // 用 didStreamTtsForTurn 判断；只有当流式 TTS 完全没出过段（极少
          // 见的"turn done 时连一段都没合成出来"）才 fallback 到整段合成。
          if (!_liveService.didStreamTtsForTurn(p.turnId)) {
            unawaited(
              _liveService.requestTts(
                doneTurn.text,
                role: agentRoleWire(doneTurn.role),
              ),
            );
          }
        }
        if (_activeStreamingTurnId == p.turnId) {
          _activeStreamingTurnId = '';
        }
        break;
      case LiveServerEventType.agentTtsChunk:
        // 第十二轮第三轮：流式 TTS 段已经在 LiveLectureService 内部按队列播放，
        // page 这里不需要任何动作；仅做 case 完整以让 dart_lints 通过。
        break;
      case LiveServerEventType.peerAssessments:
        _cancelThinkingWatchdog();
        final peerPayload = event.payload as LivePeerAssessmentsPayload;
        setState(() {
          _applyPeerAssessmentRound(
            assessments: peerPayload.assessments,
            allUnderstood: peerPayload.allUnderstood,
            status: peerPayload.status,
            masteryDelta: peerPayload.masteryDelta,
            teacherSummary: peerPayload.teacherSummary,
            committedStudent: _buildLiveStudentHistoryItem(),
            omitTeacherTurn:
                peerPayload.allUnderstood &&
                peerPayload.teacherSummary != null,
          );
          _liveStatus = _LiveStatus.idle;
        });
        _scrollToBottomSoon();
        break;
      case LiveServerEventType.roundDone:
        _cancelThinkingWatchdog();
        final p = event.payload as LiveRoundDonePayload;
        setState(() {
          _lastResponseStatus = p.status;
          _liveStatus = _LiveStatus.idle;
        });
        _scrollToBottomSoon();
        break;
      case LiveServerEventType.warning:
        // warning 只用于非致命协议提示；真实链路错误走 error。
        // 后端 no_steps_yet 之类的 warning 之后会显式补一条 listening。
        // 现在学生点「讲题结束」时已经停掉录音，所以这里回到 idle，
        // 让学生补写/补讲后重新点「开始讲题」。
        final wmsg = (event.payload as LiveWarningPayload).message;
        _cancelThinkingWatchdog();
        if (wmsg == 'no_steps_yet' && mounted) {
          final wasHint = _hintLoading;
          setState(() {
            _hintLoading = false;
            if (_liveStatus == _LiveStatus.thinking) {
              _liveStatus = _LiveStatus.idle;
            }
            _liveFailureReason =
                wasHint
                    ? '请先在白板写几步思路，再点「需要提示」。'
                    : '请先在白板写两步，或重新开始讲一段后再点「讲题结束」';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_liveFailureReason!)),
          );
        } else if (wmsg == 'thinking_in_progress' && mounted) {
          setState(() => _hintLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('同伴正在思考，请稍候再点「需要提示」。')),
          );
        } else if (wmsg == 'heartbeat') {
          // 应用层心跳，安静吃掉。
        }
        break;
      case LiveServerEventType.error:
        _cancelThinkingWatchdog();
        setState(() {
          _liveStatus = _LiveStatus.failed;
          _activeStreamingTurnId = '';
          _hintLoading = false;
          _liveFailureReason = (event.payload as LiveErrorPayload).message;
        });
        break;
      case LiveServerEventType.unknown:
        break;
    }
  }

  void _onLiveServiceError(String message) {
    if (!mounted) return;
    _cancelThinkingWatchdog();
    setState(() {
      _liveStatus = _LiveStatus.failed;
      _activeStreamingTurnId = '';
      _hintLoading = false;
      _liveFailureReason = message;
    });
  }

  void _onLiveConnection(LiveConnectionState state) {
    if (!mounted) return;
    switch (state) {
      case LiveConnectionState.connected:
        // _onStartLive 已经把状态切到 listening；这里幂等。
        // 第十二轮：service 层自动重连成功后会再发 connected 事件。
        // 此时新 ws 上对应的 LiveLectureSession 是全新实例、latest_steps
        // 重新清零；如果学生白板上有内容，必须立刻同步过去，否则学生
        // 点「讲题结束」会撞 no_steps_yet。同步推 snapshot 是幂等的：
        // 如果白板空，`_pushInkSnapshotNow` 会自然 early-return。
        _scheduleInkSnapshot(immediate: true);
        break;
      case LiveConnectionState.disconnected:
        _cancelThinkingWatchdog();
        setState(() {
          _liveStatus = _LiveStatus.disconnected;
          _activeStreamingTurnId = '';
        });
        unawaited(_audioService.stop());
        unawaited(_liveService.stopTts());
        break;
    }
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
    // 全屏白板布局不再展示对话 ListView；保留调用点供后续轻量 toast 等扩展。
  }

  PeerAssessment? _assessmentFor(AgentRole role) {
    bool roleMatches(AgentRole a, AgentRole b) {
      if (a == b) return true;
      final peer = {AgentRole.monitor, AgentRole.classLeader};
      return peer.contains(a) && peer.contains(b);
    }

    for (final a in _peerAssessments) {
      if (roleMatches(a.role, role)) return a;
    }
    return null;
  }

  AgentTurn? _latestTurnFor(AgentRole role) {
    for (var i = _turns.length - 1; i >= 0; i--) {
      if (_turns[i].role == role && _turns[i].text.trim().isNotEmpty) {
        return _turns[i];
      }
    }
    return null;
  }

  AgentRole? get _activeSpeakingRole {
    if (_liveStatus != _LiveStatus.aiSpeaking ||
        _activeStreamingTurnId.isEmpty) {
      return null;
    }
    for (var i = _turns.length - 1; i >= 0; i--) {
      if (_turns[i].turnId == _activeStreamingTurnId) {
        return _turns[i].role;
      }
    }
    return null;
  }

  bool get _teacherHasMessage =>
      _turns.any(
        (t) => t.role == AgentRole.teacher && t.text.trim().isNotEmpty,
      );

  /// 点「开始讲题」后才允许落笔；思考 / AI 发言时仍可补写。
  bool get _canDrawOnCanvas =>
      _liveStatus == _LiveStatus.listening ||
      _liveStatus == _LiveStatus.paused ||
      _liveStatus == _LiveStatus.thinking ||
      _liveStatus == _LiveStatus.aiSpeaking;

  PeerInlineMessage? _peerInlineMessage(AgentRole role) {
    final assessment = _assessmentFor(role);
    if (assessment != null &&
        !assessment.understood &&
        assessment.reason.trim().isNotEmpty) {
      return PeerInlineMessage(
        text: assessment.reason,
        highlightStepIds: assessment.highlightStepIds,
        showPlay: true,
      );
    }
    final turn = _latestTurnFor(role);
    if (turn != null && turn.text.trim().isNotEmpty) {
      return PeerInlineMessage(
        text: turn.text,
        highlightStepIds: turn.highlightStepIds,
      );
    }
    return null;
  }

  void _onPeerAvatarTap(AgentRole role) {
    if (_peerInlineMessage(role) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_defaultDisplayName(role)}还没有发言')),
      );
      return;
    }
    setState(() {
      if (_expandedPeerBubble == role) {
        _expandedPeerBubble = null;
      } else {
        _expandedPeerBubble = role;
      }
    });
  }

  void _showQuestionSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => DraggableScrollableSheet(
            initialChildSize: 0.42,
            minChildSize: 0.28,
            maxChildSize: 0.75,
            builder:
                (_, scroll) => Container(
                  decoration: const BoxDecoration(
                    color: AppPalette.surface,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppPalette.outline,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _QuestionCard(question: _question),
                    ],
                  ),
                ),
          ),
    );
  }

  void _showCompletionSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LectureSummaryCard(
                  summary: _lastSummary,
                  progress: _sectionProgressAfterCompletion,
                  gained: _lastMasteryGain,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LectureOrbButton(
                      icon: Icons.history,
                      tooltip: '再讲一遍',
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _onReplay();
                      },
                    ),
                    const SizedBox(width: 16),
                    LectureOrbButton(
                      icon: Icons.east,
                      tooltip: '下一题',
                      filled: true,
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _onContinue();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  void _showFallbackInputSheet() {
    if (_canvasController.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先在白板上写一两行思路。')));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Container(
              decoration: const BoxDecoration(
                color: AppPalette.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '用文字补充讲解',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(ctx).height * 0.4,
                    ),
                    child: SingleChildScrollView(
                      child: AnimatedBuilder(
                        animation: _canvasController,
                        builder:
                            (context, _) => _buildSemanticInputsPanel(context),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      LectureOrbButton(
                        icon: Icons.send_outlined,
                        tooltip: '提交',
                        filled: true,
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          unawaited(_onSubmit());
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
  }

  void _showErrorDialog() {
    final msg = _errorMessage ?? _liveFailureReason;
    if (msg == null) return;
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('出错了'),
            content: Text(msg),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _onRetry();
                },
                child: const Text('重试'),
              ),
            ],
          ),
    );
  }

  bool get _showFallbackOrbs =>
      _kShowLegacyTextInputByDefault ||
      _liveStatus == _LiveStatus.disconnected ||
      _liveStatus == _LiveStatus.permissionDenied ||
      _liveStatus == _LiveStatus.failed;

  @override
  Widget build(BuildContext context) {
    final total = _questions.isEmpty ? 1 : _questions.length;
    final order = _questionIndex + 1;
    final topPad = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppPalette.background,
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: UserCosmeticsPrefs.instance,
              builder:
                  (context, _) => HandCanvas(
                    controller: _canvasController,
                    penStyle: UserCosmeticsPrefs.instance.penStyle,
                    backgroundColor: AppPalette.surface,
                    edgeToEdge: true,
                    drawingEnabled: _canDrawOnCanvas,
                    stylusOnly: true,
                    drawMode: _canvasDrawMode,
                    twoFingerPanEnabled: true,
                  ),
            ),
          ),
          Positioned(
            left: 8,
            top: topPad + 6,
            right: 220,
            child: _buildQuestionDock(order: order, total: total),
          ),
          Positioned(
            right: 8,
            top: topPad + 72,
            bottom: MediaQuery.paddingOf(context).bottom + 88,
            child: AnimatedBuilder(
              animation: _reasonPlayback,
              builder:
                  (context, _) => SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: LecturePeerRail(
                      assessments: _peerAssessments,
                      playingRole: _reasonPlayback.playingRole,
                      activeSpeakingRole: _activeSpeakingRole,
                      teacherHasMessage: _teacherHasMessage,
                      expandedRole: _expandedPeerBubble,
                      messageForRole: _peerInlineMessage,
                      onAvatarTap: _onPeerAvatarTap,
                      onPlayAudio:
                          (role) => unawaited(_reasonPlayback.playPeer(role)),
                      onHighlightSteps: (_, ids) {
                        _canvasController.setHighlight(ids);
                      },
                    ),
                  ),
            ),
          ),
          Positioned(
            left: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 12,
            child: _buildOrbToolbar(),
          ),
          if (_status == _LectureStatus.submitting ||
              _liveStatus == _LiveStatus.thinking)
            Positioned(
              left: 0,
              right: 72,
              bottom: MediaQuery.paddingOf(context).bottom + 72,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _liveStatus == _LiveStatus.thinking
                            ? '同伴正在想怎么追问…'
                            : '正在让同学听讲…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_status == _LectureStatus.error && _errorMessage != null)
            Positioned(
              left: 12,
              top: topPad + 52,
              child: LectureOrbButton(
                icon: Icons.error_outline,
                accent: AppPalette.error,
                filled: true,
                tooltip: '查看错误',
                onPressed: _showErrorDialog,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQuestionDock({required int order, required int total}) {
    final maxDockHeight = MediaQuery.sizeOf(context).height * 0.32;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            LectureOrbButton(
              icon: Icons.arrow_back,
              tooltip: '返回',
              size: 44,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_question.sectionLabel} · 第 $order / $total 题',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppPalette.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            LectureOrbButton(
              icon: Icons.unfold_more,
              tooltip: '全屏查看题面',
              size: 40,
              onPressed: _showQuestionSheet,
            ),
            const SizedBox(width: 6),
            AnimatedBuilder(
              animation: ProgressRepository.instance,
              builder: (context, _) {
                final p = ProgressRepository.instance.progressFor(
                  widget.section.id,
                );
                return _MasteryBadge(round: _round, progress: p);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxDockHeight),
          child: Material(
            color: AppPalette.surface.withValues(alpha: 0.96),
            elevation: 1,
            shadowColor: AppPalette.textPrimary.withValues(alpha: 0.08),
            borderRadius: AppRadius.cardR,
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: _QuestionCard(
                question: _question,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrbToolbar() {
    final submitting = _status == _LectureStatus.submitting;
    final canSubmit =
        (_status == _LectureStatus.idle ||
            _status == _LectureStatus.awaiting ||
            _status == _LectureStatus.error) &&
        !_canvasController.isEmpty;
    final listening =
        _liveStatus == _LiveStatus.listening ||
        _liveStatus == _LiveStatus.paused;
    final orbs = <Widget>[];

    switch (_panelState) {
      case RealtimeAudioPanelState.idle:
        orbs.add(
          LectureOrbButton(
            icon: Icons.mic,
            tooltip: '开始讲题',
            filled: true,
            onPressed: submitting ? null : _onStartLive,
          ),
        );
        break;
      case RealtimeAudioPanelState.listening:
      case RealtimeAudioPanelState.paused:
        orbs.addAll([
          LectureOrbButton(
            icon: Icons.mic,
            tooltip: '正在听',
            filled: true,
            accent: AppPalette.error,
            pulse: true,
            onPressed: _onStopLive,
          ),
          LectureOrbButton(
            icon: Icons.stop_circle_outlined,
            tooltip: '讲题结束',
            filled: true,
            onPressed: listening ? _onManualPause : null,
          ),
        ]);
        break;
      case RealtimeAudioPanelState.thinking:
        orbs.add(
          LectureOrbButton(
            icon: Icons.mic,
            tooltip: '思考中',
            loading: true,
            onPressed: null,
          ),
        );
        break;
      case RealtimeAudioPanelState.aiSpeaking:
        orbs.add(
          LectureOrbButton(
            icon: Icons.stop_circle_outlined,
            tooltip: '结束本题',
            filled: true,
            onPressed: _onEndLiveSession,
          ),
        );
        break;
      case RealtimeAudioPanelState.disconnected:
        orbs.add(
          LectureOrbButton(
            icon: Icons.refresh,
            tooltip: '重新连接',
            filled: true,
            onPressed: _onStartLive,
          ),
        );
        break;
      case RealtimeAudioPanelState.permissionDenied:
      case RealtimeAudioPanelState.failed:
        orbs.add(
          LectureOrbButton(
            icon: Icons.mic_off,
            tooltip: '语音不可用',
            accent: AppPalette.error,
            onPressed: _onFallbackTextSubmit,
          ),
        );
        break;
      case RealtimeAudioPanelState.interrupted:
        break;
    }

    final canvasToolsEnabled = _canDrawOnCanvas && !submitting;

    orbs.addAll([
      LectureOrbButton(
        icon: Icons.lightbulb_outline,
        tooltip: '需要提示',
        onPressed:
            submitting || _hintLoading || _liveStatus == _LiveStatus.thinking
                ? null
                : _onRequestHint,
        loading: _hintLoading,
      ),
      LectureOrbButton(
        icon: Icons.edit_outlined,
        tooltip: '画笔',
        filled: _canvasDrawMode == CanvasDrawMode.pen,
        onPressed:
            canvasToolsEnabled
                ? () => setState(() => _canvasDrawMode = CanvasDrawMode.pen)
                : null,
      ),
      LectureOrbButton(
        icon: Icons.auto_fix_off_outlined,
        tooltip: '橡皮擦',
        filled: _canvasDrawMode == CanvasDrawMode.eraser,
        onPressed:
            canvasToolsEnabled
                ? () => setState(() => _canvasDrawMode = CanvasDrawMode.eraser)
                : null,
      ),
      LectureOrbButton(
        icon: Icons.undo,
        tooltip: '撤销',
        onPressed:
            _canvasController.canUndo && canvasToolsEnabled
                ? _canvasController.undo
                : null,
      ),
      LectureOrbButton(
        icon: Icons.cleaning_services_outlined,
        tooltip: '清空',
        onPressed:
            _canvasController.isEmpty || !canvasToolsEnabled
                ? null
                : _canvasController.clear,
      ),
    ]);

    if (_showFallbackOrbs) {
      orbs.add(
        LectureOrbButton(
          icon:
              _status == _LectureStatus.error
                  ? Icons.replay
                  : Icons.send_outlined,
          tooltip: '文字提交',
          filled: true,
          loading: submitting,
          onPressed:
              canSubmit && !submitting ? _showFallbackInputSheet : null,
        ),
      );
    }

    if (_status == _LectureStatus.finished &&
        _lastResponseStatus == 'completed') {
      orbs.addAll([
        LectureOrbButton(
          icon: Icons.history,
          tooltip: '再讲一遍',
          onPressed: _onReplay,
        ),
        LectureOrbButton(
          icon: Icons.east,
          tooltip: '下一题',
          filled: true,
          onPressed: _onContinue,
        ),
        LectureOrbButton(
          icon: Icons.celebration_outlined,
          tooltip: '查看小结',
          accent: AppPalette.primaryAccent,
          onPressed: _showCompletionSheet,
        ),
      ]);
    }

    if (_debugOcr) {
      orbs.add(
        LectureOrbButton(
          icon: Icons.bug_report_outlined,
          tooltip: 'DEBUG OCR',
          onPressed: () => _showDebugOcrSheet(),
        ),
      );
    }

    return Wrap(spacing: 10, runSpacing: 10, children: orbs);
  }

  void _showDebugOcrSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: _buildDebugOcrPanel(),
      ),
    );
  }

  /// 实时面板的"用文字提交"入口。
  ///
  /// 当 WS / 麦克风 / 录音库出问题时，学生可以手动改用
  /// `/lecture/submit` 路径提交本题（底部 sheet 补充文字，不占白板）。
  void _onFallbackTextSubmit() {
    _showFallbackInputSheet();
  }

  Widget _buildDebugOcrPanel() {
    return ValueListenableBuilder<List<OcrStepGuess>>(
      valueListenable: OcrService.debugGuesses,
      builder: (context, guesses, _) {
        return ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
          collapsedShape: const RoundedRectangleBorder(
            borderRadius: AppRadius.buttonR,
          ),
          backgroundColor: AppPalette.surface,
          collapsedBackgroundColor: AppPalette.surface,
          title: const Text('DEBUG OCR / HWR'),
          subtitle: Text(
            guesses.isEmpty ? '暂无识别结果' : '${guesses.length} 个 step',
          ),
          children:
              guesses.isEmpty
                  ? const [
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '写字后等待 480ms 或提交讲解即可看到 source/confidence/mode。',
                      ),
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
    final speechSubtitle = hasFollowup ? 'AI 同伴会先评估你的回答' : 'AI 同伴会照着这段话追问';
    final speechHint =
        hasFollowup
            ? '例如：我补充一下，这一步用到的条件是……所以可以这样推。'
            : '例如：我先读题目条件，再说明第一步为什么能推出下一步。';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        boxShadow: AppShadows.paper,
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
              const Icon(
                Icons.format_list_numbered_outlined,
                size: 18,
                color: AppPalette.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text('为每一步补充一句话（可选）', style: theme.textTheme.titleSmall),
              ),
              if (stepIds.isNotEmpty)
                Text('共 ${stepIds.length} 步', style: theme.textTheme.bodySmall),
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
        color: AppPalette.canvas,
        borderRadius: BorderRadius.circular(12),
        boxShadow: AppShadows.paper,
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
                  hintText: '例如：这一步用了题目里的已知条件',
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
                  latexExpanded ? Icons.expand_less : Icons.functions_outlined,
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
              hintText: r'可选 LaTeX：x+1=3',
            ),
          ],
        ],
      ),
    );
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
    final preview =
        turn.text.length > 80 ? '${turn.text.substring(0, 80)}…' : turn.text;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.help_outline, size: 16, color: AppPalette.primary),
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

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question});

  final LectureQuestion question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.05),
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FormulaText(
            question.prompt,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
            formulaStyle: theme.textTheme.bodyLarge?.copyWith(
              color: AppPalette.primary,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
          if (question.image != null) ...[
            const SizedBox(height: 12),
            _QuestionImage(image: question.image!),
          ],
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
          final h = (w * 0.52).clamp(120.0, 200.0);
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppPalette.surface,
              borderRadius: AppRadius.cardR,
              border: Border.all(color: AppPalette.outline),
            ),
            child: SvgPicture.asset(
              image.asset,
              width: w - 20,
              height: h,
              fit: BoxFit.contain,
              alignment: Alignment.center,
              placeholderBuilder:
                  (context) => SizedBox(
                    height: h,
                    child: const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              errorBuilder: (context, error, stackTrace) {
                return SizedBox(
                  height: h,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.image_not_supported_outlined,
                        color: AppPalette.textSecondary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        image.alt,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppPalette.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '配图未能加载',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppPalette.error,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
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
        fillColor: AppPalette.canvas,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: dense ? 10 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppPalette.outline.withValues(alpha: 0.55)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppPalette.outline.withValues(alpha: 0.45)),
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
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.28)),
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
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
