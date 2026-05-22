import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/round12_models.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'lecture_page.dart';

class DailyChallengePage extends StatefulWidget {
  const DailyChallengePage({super.key});

  @override
  State<DailyChallengePage> createState() => _DailyChallengePageState();
}

class _DailyChallengePageState extends State<DailyChallengePage> {
  final _service = Round12Service();
  late Future<BountyToday> _future = _service.fetchBountyToday();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Map<String, num>> _circledBoxes = {};
  final Map<String, BountySubmitResult> _results = {};
  int _selectedIndex = 0;
  bool _submitting = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _service.close();
    super.dispose();
  }

  TextEditingController _controllerFor(BountyChallenge challenge) {
    return _controllers.putIfAbsent(
      challenge.challengeId,
      () => TextEditingController(),
    );
  }

  Future<void> _submit(BountyChallenge challenge) async {
    final box = _circledBoxes[challenge.challengeId];
    final text = _controllerFor(challenge).text.trim();
    if (box == null || box['width'] == 0 || box['height'] == 0) {
      _showMessage('请先用红框圈出你认为出错的那一步。');
      return;
    }
    if (text.isEmpty) {
      _showMessage('请先写下你的纠错讲解。');
      return;
    }
    setState(() => _submitting = true);
    try {
      final result = await _service.submitBounty(
        challengeId: challenge.challengeId,
        circledBox: box,
        transcriptText: text,
      );
      if (!mounted) return;
      setState(() {
        _results[challenge.challengeId] = result;
        _future = _service.fetchBountyToday();
      });
    } catch (e) {
      if (mounted) _showMessage('提交失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _openLecture(BountyChallenge challenge) {
    final section = CurriculumSection(
      id: challenge.sectionId,
      number: challenge.sectionLabel.split(' ').first,
      title: challenge.sectionLabel.isEmpty ? '每日挑战复盘' : challenge.sectionLabel,
      label: challenge.sectionLabel.isEmpty ? challenge.sectionId : challenge.sectionLabel,
      type: 'lesson',
      contentStatus: 'available',
      v1Launch: true,
    );
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => LecturePage(section: section)));
  }

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: '每日挑战',
      maxWidth: 1080,
      child: FutureBuilder<BountyToday>(
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
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.pageEdge),
              child: _EmptyChallengeCard(),
            );
          }
          final safeIndex = math.min(_selectedIndex, challenges.length - 1);
          final selected = challenges[safeIndex];
          final result = _results[selected.challengeId];
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _TodaySummaryCard(today: today),
              const SizedBox(height: 14),
              _ChallengeSelector(
                challenges: challenges,
                selectedIndex: safeIndex,
                onSelected: (index) => setState(() => _selectedIndex = index),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final work = _ChallengeWorkCard(
                    challenge: selected,
                    controller: _controllerFor(selected),
                    initialBox: _circledBoxes[selected.challengeId],
                    result: result,
                    submitting: _submitting,
                    onBoxChanged:
                        (box) => _circledBoxes[selected.challengeId] = box,
                    onSubmit: () => _submit(selected),
                    onLecture: () => _openLecture(selected),
                  );
                  if (!wide) return work;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: work),
                      const SizedBox(width: 14),
                      Expanded(
                        flex: 4,
                        child: _ResultGuideCard(
                          challenge: selected,
                          result: result,
                          onLecture: () => _openLecture(selected),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

Widget _loadingOrError(AsyncSnapshot snapshot, VoidCallback retry) {
  if (snapshot.hasError) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：${snapshot.error}', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
  return const Center(child: CircularProgressIndicator());
}

class _TodaySummaryCard extends StatelessWidget {
  const _TodaySummaryCard({required this.today});

  final BountyToday today;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      tone: StudyPanelTone.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '今天的 3 个找错任务',
            subtitle: '先圈出错误，再讲清错因。每题首次完成才发放晶石和章节战力。',
            icon: Icons.where_to_vote_outlined,
            action: Text(today.dateKey),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              StudyStatPill(
                label: '今日进度',
                value: '${today.completedCount}/${today.totalCount}',
                icon: Icons.check_circle_outline,
              ),
              StudyStatPill(
                label: '可得晶石',
                value: '${today.totalCrystals} 颗',
                icon: Icons.diamond_outlined,
                accent: AppPalette.primaryAccent,
              ),
              const StudyStatPill(
                label: '刷新节奏',
                value: '明天更新',
                icon: Icons.calendar_today_outlined,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChallengeSelector extends StatelessWidget {
  const _ChallengeSelector({
    required this.challenges,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<BountyChallenge> challenges;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < challenges.length; i++)
          ChoiceChip(
            selected: selectedIndex == i,
            onSelected: (_) => onSelected(i),
            label: Text(
              '${_trackLabel(challenges[i].track)} · ${_difficultyLabel(challenges[i].difficulty)}'
              '${challenges[i].isCompleted ? ' · 已完成' : ''}',
            ),
          ),
      ],
    );
  }
}

class _ChallengeWorkCard extends StatelessWidget {
  const _ChallengeWorkCard({
    required this.challenge,
    required this.controller,
    required this.initialBox,
    required this.result,
    required this.submitting,
    required this.onBoxChanged,
    required this.onSubmit,
    required this.onLecture,
  });

  final BountyChallenge challenge;
  final TextEditingController controller;
  final Map<String, num>? initialBox;
  final BountySubmitResult? result;
  final bool submitting;
  final ValueChanged<Map<String, num>> onBoxChanged;
  final VoidCallback onSubmit;
  final VoidCallback onLecture;

  @override
  Widget build(BuildContext context) {
    final submitResult = result;
    return StudyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: challenge.sectionLabel.isEmpty
                ? challenge.sectionId
                : challenge.sectionLabel,
            subtitle: '奖励 ${challenge.rewardCrystals} 晶石 / ${challenge.rewardPower} 战力',
            icon: Icons.task_alt_outlined,
          ),
          const SizedBox(height: 12),
          FormulaText(
            challenge.prompt,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SmallTag(_trackLabel(challenge.track)),
              _SmallTag(_difficultyLabel(challenge.difficulty)),
              ...challenge.tags.take(3).map(_SmallTag.new),
            ],
          ),
          const SizedBox(height: 14),
          _BountyCanvas(
            key: ValueKey(challenge.challengeId),
            challenge: challenge,
            initialBox: initialBox,
            onChanged: onBoxChanged,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '把你的纠错讲解写在这里',
              hintText: '例如：错在……正确规则是……所以应该……',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: submitting ? null : onSubmit,
                icon: submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(challenge.isCompleted ? '再次提交讲解' : '提交圈选与讲解'),
              ),
              OutlinedButton.icon(
                onPressed: onLecture,
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('继续讲清本节'),
              ),
            ],
          ),
          if (submitResult != null) ...[
            const SizedBox(height: 12),
            _InlineResult(result: submitResult),
          ],
        ],
      ),
    );
  }
}

class _ResultGuideCard extends StatelessWidget {
  const _ResultGuideCard({
    required this.challenge,
    required this.result,
    required this.onLecture,
  });

  final BountyChallenge challenge;
  final BountySubmitResult? result;
  final VoidCallback onLecture;

  @override
  Widget build(BuildContext context) {
    final feedback = result?.feedback ?? challenge.feedback;
    final hasFeedback = feedback.summary.isNotEmpty;
    return StudyPanel(
      tone: hasFeedback ? StudyPanelTone.accent : StudyPanelTone.quiet,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: challenge.isCompleted ? '已完成' : '挑战反馈',
            subtitle: hasFeedback ? feedback.summary : '提交后会看到圈选命中、讲解得分和下一步建议。',
            icon: Icons.tips_and_updates_outlined,
          ),
          const SizedBox(height: 12),
          if (hasFeedback) ...[
            StudyStatPill(
              label: '圈选 IoU',
              value: feedback.iouScore.toStringAsFixed(2),
              icon: Icons.crop_free_outlined,
            ),
            const SizedBox(height: 10),
            StudyStatPill(
              label: '讲解分',
              value: '${feedback.explanationScore}/100',
              icon: Icons.psychology_alt_outlined,
              accent: AppPalette.primaryAccent,
            ),
            const SizedBox(height: 12),
            Text(feedback.nextHint),
          ] else
            const Text('建议先找“规则被用错”的那一行，而不是圈整道题。'),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onLecture,
            child: const Text('去讲题页完整复盘'),
          ),
        ],
      ),
    );
  }
}

class _BountyCanvas extends StatefulWidget {
  const _BountyCanvas({
    super.key,
    required this.challenge,
    required this.initialBox,
    required this.onChanged,
  });

  final BountyChallenge challenge;
  final Map<String, num>? initialBox;
  final ValueChanged<Map<String, num>> onChanged;

  @override
  State<_BountyCanvas> createState() => _BountyCanvasState();
}

class _BountyCanvasState extends State<_BountyCanvas> {
  Offset? _start;
  Rect? _box;

  @override
  void initState() {
    super.initState();
    _box = _rectFromMap(widget.initialBox);
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.challenge.canvasWidth / widget.challenge.canvasHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            onPanStart: (details) {
              _start = _clamp(details.localPosition, size);
              _updateBox(_start!, _start!, size);
            },
            onPanUpdate: (details) {
              final start = _start;
              if (start == null) return;
              _updateBox(start, _clamp(details.localPosition, size), size);
            },
            child: CustomPaint(
              foregroundPainter: _BountyCanvasPainter(
                box: _box,
                canvasSize: Size(
                  widget.challenge.canvasWidth.toDouble(),
                  widget.challenge.canvasHeight.toDouble(),
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppPalette.surface,
                  borderRadius: AppRadius.cardR,
                  border: Border.all(color: AppPalette.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final line in widget.challenge.wrongSolution)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: FormulaText(
                          line,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Offset _clamp(Offset value, Size size) {
    return Offset(
      value.dx.clamp(0, size.width).toDouble(),
      value.dy.clamp(0, size.height).toDouble(),
    );
  }

  void _updateBox(Offset a, Offset b, Size localSize) {
    final local = Rect.fromPoints(a, b);
    final scaleX = widget.challenge.canvasWidth / localSize.width;
    final scaleY = widget.challenge.canvasHeight / localSize.height;
    final canvas = Rect.fromLTWH(
      local.left * scaleX,
      local.top * scaleY,
      local.width * scaleX,
      local.height * scaleY,
    );
    setState(() => _box = canvas);
    widget.onChanged({
      'x': canvas.left.round(),
      'y': canvas.top.round(),
      'width': canvas.width.round(),
      'height': canvas.height.round(),
    });
  }

  Rect? _rectFromMap(Map<String, num>? raw) {
    if (raw == null) return null;
    return Rect.fromLTWH(
      (raw['x'] ?? 0).toDouble(),
      (raw['y'] ?? 0).toDouble(),
      (raw['width'] ?? 0).toDouble(),
      (raw['height'] ?? 0).toDouble(),
    );
  }
}

class _BountyCanvasPainter extends CustomPainter {
  const _BountyCanvasPainter({required this.box, required this.canvasSize});

  final Rect? box;
  final Size canvasSize;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = AppPalette.error;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = AppPalette.error.withValues(alpha: 0.08);
    final raw = box;
    if (raw == null || raw.width <= 0 || raw.height <= 0) return;
    final scaled = Rect.fromLTWH(
      raw.left / canvasSize.width * size.width,
      raw.top / canvasSize.height * size.height,
      raw.width / canvasSize.width * size.width,
      raw.height / canvasSize.height * size.height,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(scaled, const Radius.circular(12)), fill);
    canvas.drawRRect(RRect.fromRectAndRadius(scaled, const Radius.circular(12)), paint);
  }

  @override
  bool shouldRepaint(covariant _BountyCanvasPainter oldDelegate) {
    return oldDelegate.box != box || oldDelegate.canvasSize != canvasSize;
  }
}

class _InlineResult extends StatelessWidget {
  const _InlineResult({required this.result});

  final BountySubmitResult result;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      tone: result.completed ? StudyPanelTone.accent : StudyPanelTone.danger,
      padding: const EdgeInsets.all(12),
      child: Text(
        result.completed
            ? '挑战完成：本次获得 ${result.crystalReward} 晶石 / ${result.powerReward} 战力。'
            : result.feedback.summary,
      ),
    );
  }
}

class _SmallTag extends StatelessWidget {
  const _SmallTag(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: AppPalette.primary.withValues(alpha: 0.18)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _EmptyChallengeCard extends StatelessWidget {
  const _EmptyChallengeCard();

  @override
  Widget build(BuildContext context) {
    return const StudyPanel(
      child: SectionHeader(
        title: '今天暂时没有挑战',
        subtitle: '题库正在整理中，先回到课程目录完成一题讲题练习吧。',
        icon: Icons.inbox_outlined,
      ),
    );
  }
}

String _trackLabel(String track) {
  return switch (track) {
    'weak' => '弱项',
    'advanced' => '进阶',
    _ => '复习',
  };
}

String _difficultyLabel(int difficulty) {
  return switch (difficulty) {
    3 => '挑战',
    2 => '巩固',
    _ => '基础',
  };
}
