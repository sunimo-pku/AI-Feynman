import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/lecture_models.dart';
import '../data/mock_lecture_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/agent_message_bubble.dart';
import '../widgets/formula_text.dart';
import '../widgets/hand_canvas.dart';

/// 讲题页：左侧多 Agent 对话区，右侧手写板（横屏），手机竖屏降级为上下布局。
///
/// V1 闭环 = 学生书写步骤 → 提交 → Mock 多 Agent 追问 → 「我懂了 / 下一题」。
class LecturePage extends StatefulWidget {
  const LecturePage({
    super.key,
    required this.section,
  });

  final CurriculumSection section;

  @override
  State<LecturePage> createState() => _LecturePageState();
}

enum _LectureStatus { idle, submitting, awaiting, finished }

class _LecturePageState extends State<LecturePage> {
  final HandCanvasController _canvasController = HandCanvasController();
  final ScrollController _discussionScrollController = ScrollController();

  late LectureQuestion _question;
  final List<AgentTurn> _turns = <AgentTurn>[];
  _LectureStatus _status = _LectureStatus.idle;
  int _round = 0;

  @override
  void initState() {
    super.initState();
    _question = MockLectureRepository.instance.questionForSection(widget.section.id);
    _turns.add(_introTurn());
  }

  @override
  void dispose() {
    _canvasController.dispose();
    _discussionScrollController.dispose();
    super.dispose();
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

  Future<void> _onSubmit() async {
    if (_status == _LectureStatus.submitting) return;
    final stepIds = _canvasController.collectStepIds();
    if (stepIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('画板还没有内容，先把你的思路写一两行再提交吧。'),
        ),
      );
      return;
    }
    setState(() {
      _status = _LectureStatus.submitting;
      _round += 1;
      _turns.add(AgentTurn(
        role: AgentRole.system,
        displayName: '系统',
        text: '已收到第 $_round 轮讲解，正在让小明和李老师听你的步骤……',
        highlightStepIds: const [],
      ));
    });
    _scrollToBottomSoon();

    final discussion = await MockLectureRepository.instance.submitExplanation(
      sectionId: widget.section.id,
      stepIds: stepIds,
    );

    if (!mounted) return;

    setState(() {
      _turns.addAll(discussion.turns);
      _status = _LectureStatus.awaiting;
    });

    final highlightFromFirst = discussion.turns
        .expand((t) => t.highlightStepIds)
        .toSet();
    if (highlightFromFirst.isNotEmpty) {
      _canvasController.setHighlight(highlightFromFirst);
    }
    _scrollToBottomSoon();
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
    setState(() {
      _status = _LectureStatus.idle;
      _turns
        ..clear()
        ..add(_introTurn());
      _round = 0;
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
            child: Center(
              child: _MasteryBadge(round: _round),
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
              Text(
                '多 Agent 讨论 · ${_question.sectionLabel}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _QuestionCard(question: _question),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              controller: _discussionScrollController,
              itemCount: _turns.length + (_status == _LectureStatus.submitting ? 1 : 0),
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
                      : () =>
                          _canvasController.setHighlight(turn.highlightStepIds),
                );
              },
            ),
          ),
          if (_status == _LectureStatus.awaiting || _status == _LectureStatus.finished) ...[
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
    final canSubmit = _status == _LectureStatus.idle || _status == _LectureStatus.awaiting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.edit_outlined, size: 20, color: AppPalette.primary),
            const SizedBox(width: 8),
            Text(
              '手写板 · 写出你的解题步骤',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
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
        AnimatedBuilder(
          animation: _canvasController,
          builder: (context, _) {
            return Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _canvasController.canUndo ? _canvasController.undo : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('撤销'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _canvasController.isEmpty ? null : _canvasController.clear,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('清空'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: canSubmit && !_canvasController.isEmpty ? _onSubmit : null,
                  icon: _status == _LectureStatus.submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_outlined),
                  label: Text(
                    _status == _LectureStatus.submitting
                        ? '正在让同学听讲…'
                        : (_round == 0 ? '提交讲解' : '再讲一轮'),
                  ),
                ),
              ],
            );
          },
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
            '同学们正在仔细看你的步骤……',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
          ),
        ],
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
