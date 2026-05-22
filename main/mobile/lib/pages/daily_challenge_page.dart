import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/round12_models.dart';
import '../services/asr_service.dart';
import '../services/audio_stream_service.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bounty_step_quiz_bar.dart';
import '../widgets/formula_text.dart';
import '../widgets/hand_canvas.dart';
import '../widgets/lecture_orb_button.dart';

/// 每日挑战：错误解法拆成逐步选择题 + 全屏白板语音讲解。
class DailyChallengePage extends StatefulWidget {
  const DailyChallengePage({super.key});

  @override
  State<DailyChallengePage> createState() => _DailyChallengePageState();
}

class _DailyChallengePageState extends State<DailyChallengePage> {
  final _service = Round12Service();
  final _asr = AsrService();
  final _audio = AudioStreamService();
  final _canvas = HandCanvasController();

  late Future<BountyToday> _future = _service.fetchBountyToday();
  final Map<String, Map<String, String>> _stepAnswersByChallenge = {};
  final Map<String, BountySubmitResult> _results = {};
  final Map<String, int> _quizIndexByChallenge = {};

  int _selectedIndex = 0;
  bool _submitting = false;
  bool _listening = false;
  final List<Uint8List> _pcmBuffer = <Uint8List>[];

  @override
  void initState() {
    super.initState();
    _audio.chunks.listen(_onPcmChunk);
    _audio.statusStream.listen(_onAudioStatus);
  }

  @override
  void dispose() {
    _canvas.dispose();
    unawaited(_audio.stop());
    _audio.dispose();
    _asr.close();
    _service.close();
    super.dispose();
  }

  void _onPcmChunk(Uint8List chunk) {
    if (!_listening || chunk.isEmpty) return;
    _pcmBuffer.add(Uint8List.fromList(chunk));
  }

  void _onAudioStatus(AudioStreamStatus status) {
    if (!mounted) return;
    if (status == AudioStreamStatus.permissionDenied ||
        status == AudioStreamStatus.failed) {
      setState(() => _listening = false);
      _showMessage(_audio.failureReason ?? '麦克风不可用');
    }
  }

  Map<String, String> _answersFor(String challengeId) {
    return _stepAnswersByChallenge.putIfAbsent(challengeId, () => {});
  }

  int _quizIndexFor(String challengeId) {
    return _quizIndexByChallenge[challengeId] ?? 0;
  }

  bool _allStepsAnswered(BountyChallenge challenge) {
    final quizzes = challenge.stepQuizzes;
    if (quizzes.isEmpty) return false;
    final answers = _answersFor(challenge.challengeId);
    for (final q in quizzes) {
      if (!answers.containsKey(q.stepId)) return false;
    }
    return true;
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _startVoice() async {
    _pcmBuffer.clear();
    final ok = await _audio.start();
    if (!mounted) return;
    if (!ok) {
      _showMessage(_audio.failureReason ?? '无法开始录音');
      return;
    }
    setState(() => _listening = true);
  }

  Future<void> _stopVoiceAndSubmit(BountyChallenge challenge) async {
    if (_listening) {
      await _audio.stop();
      setState(() => _listening = false);
    }

    if (!_allStepsAnswered(challenge)) {
      _showMessage('请先完成上方每一步的选择题。');
      return;
    }

    setState(() => _submitting = true);
    try {
      final merged = Uint8List(
        _pcmBuffer.fold<int>(0, (sum, c) => sum + c.length),
      );
      var offset = 0;
      for (final c in _pcmBuffer) {
        merged.setRange(offset, offset + c.length, c);
        offset += c.length;
      }

      final answers = _answersFor(challenge.challengeId);
      final stepPayload = challenge.stepQuizzes
          .map(
            (q) => {
              'stepId': q.stepId,
              'optionId': answers[q.stepId]!,
            },
          )
          .toList(growable: false);

      final transcript = await _asr.transcribePcm16(merged);
      final result = await _service.submitBounty(
        challengeId: challenge.challengeId,
        stepAnswers: stepPayload,
        transcriptText: transcript,
      );
      if (!mounted) return;
      setState(() {
        _results[challenge.challengeId] = result;
        _future = _service.fetchBountyToday();
      });
      _showResultSheet(result);
    } on AsrServiceException catch (e) {
      if (mounted) _showMessage(e.message);
    } catch (e) {
      if (mounted) _showMessage('提交失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showResultSheet(BountySubmitResult result) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Material(
              borderRadius: BorderRadius.circular(20),
              color: AppPalette.surface,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.completed ? '挑战完成' : '继续加油',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      result.completed
                          ? '获得 ${result.crystalReward} 晶石 · ${result.powerReward} 战力'
                          : result.feedback.summary,
                    ),
                    if (result.feedback.nextHint.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        result.feedback.nextHint,
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: LectureOrbButton(
                        icon: Icons.check,
                        tooltip: '知道了',
                        filled: true,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  void _showPromptSheet(BountyChallenge challenge) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => DraggableScrollableSheet(
            initialChildSize: 0.35,
            minChildSize: 0.22,
            maxChildSize: 0.6,
            builder:
                (_, scroll) => Container(
                  decoration: const BoxDecoration(
                    color: AppPalette.surface,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: ListView(
                    controller: scroll,
                    children: [
                      FormulaText(
                        challenge.prompt,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      body: FutureBuilder<BountyToday>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _loadingOrError(
              snapshot,
              () => setState(() => _future = _service.fetchBountyToday()),
            );
          }
          final today = snapshot.data!;
          final challenges = today.challenges;
          if (challenges.isEmpty) {
            return const SafeArea(
              child: Center(child: Text('今天暂时没有挑战')),
            );
          }
          final safeIndex = math.min(_selectedIndex, challenges.length - 1);
          final challenge = challenges[safeIndex];
          final result = _results[challenge.challengeId];
          final topPad = MediaQuery.paddingOf(context).top;
          final quizIdx = _quizIndexFor(challenge.challengeId);

          return Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: topPad + 8),
                  _buildTopBar(today: today, challenges: challenges, index: safeIndex),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: _buildPromptPill(challenge),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: BountyStepQuizBar(
                      quizzes: challenge.stepQuizzes,
                      currentIndex: quizIdx,
                      answers: _answersFor(challenge.challengeId),
                      onPick: (stepId, optionId) {
                        setState(() {
                          _answersFor(challenge.challengeId)[stepId] = optionId;
                        });
                      },
                      onPrev:
                          quizIdx > 0
                              ? () => setState(() {
                                _quizIndexByChallenge[challenge.challengeId] =
                                    quizIdx - 1;
                              })
                              : null,
                      onNext:
                          quizIdx < challenge.stepQuizzes.length - 1
                              ? () => setState(() {
                                _quizIndexByChallenge[challenge.challengeId] =
                                    quizIdx + 1;
                              })
                              : null,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
                    child: Text(
                      '白板：写出正确做法，语音讲清为什么错',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: HandCanvas(
                      controller: _canvas,
                      edgeToEdge: true,
                      backgroundColor: AppPalette.surface,
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 12,
                bottom: MediaQuery.paddingOf(context).bottom + 12,
                child: _buildOrbToolbar(challenge, result),
              ),
              if (_submitting)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0x33FFFFFF),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopBar({
    required BountyToday today,
    required List<BountyChallenge> challenges,
    required int index,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          LectureOrbButton(
            icon: Icons.arrow_back,
            size: 44,
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '每日挑战 ${today.completedCount}/${today.totalCount}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (var i = 0; i < challenges.length; i++) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => setState(() {
                _selectedIndex = i;
                _canvas.clear();
              }),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index == i ? AppPalette.primary : AppPalette.surface,
                  border: Border.all(
                    color:
                        challenges[i].isCompleted
                            ? const Color(0xFF16A34A)
                            : AppPalette.outlineSoft,
                  ),
                ),
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: index == i ? Colors.white : AppPalette.primary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPromptPill(BountyChallenge challenge) {
    return Material(
      color: AppPalette.surface.withValues(alpha: 0.94),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showPromptSheet(challenge),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  challenge.prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOrbToolbar(BountyChallenge challenge, BountySubmitResult? result) {
    final canSubmit = _allStepsAnswered(challenge);
    final orbs = <Widget>[
      if (!_listening)
        LectureOrbButton(
          icon: Icons.mic,
          tooltip: '开始讲错因',
          filled: true,
          onPressed: _submitting ? null : _startVoice,
        )
      else
        LectureOrbButton(
          icon: Icons.mic,
          tooltip: '录音中',
          filled: true,
          accent: AppPalette.error,
          pulse: true,
          onPressed: _submitting ? null : () => unawaited(_audio.stop()),
        ),
      LectureOrbButton(
        icon: Icons.stop_circle_outlined,
        tooltip: '讲完并提交',
        filled: true,
        loading: _submitting,
        onPressed:
            _submitting || !canSubmit
                ? null
                : () => unawaited(_stopVoiceAndSubmit(challenge)),
      ),
      LectureOrbButton(
        icon: Icons.undo,
        tooltip: '撤销',
        onPressed: _canvas.canUndo ? _canvas.undo : null,
      ),
      LectureOrbButton(
        icon: Icons.cleaning_services_outlined,
        tooltip: '清空白板',
        onPressed: _canvas.isEmpty ? null : _canvas.clear,
      ),
    ];
    if (result != null) {
      orbs.add(
        LectureOrbButton(
          icon: Icons.feedback_outlined,
          tooltip: '反馈',
          onPressed: () => _showResultSheet(result),
        ),
      );
    }
    return Wrap(spacing: 10, runSpacing: 10, children: orbs);
  }
}

Widget _loadingOrError(AsyncSnapshot snapshot, VoidCallback retry) {
  if (snapshot.hasError) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败：${snapshot.error}'),
          const SizedBox(height: 12),
          FilledButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    );
  }
  return const Center(child: CircularProgressIndicator());
}
