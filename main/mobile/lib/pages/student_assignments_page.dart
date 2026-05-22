import 'package:flutter/material.dart';

import '../data/assignment_models.dart';
import '../data/curriculum_models.dart';
import '../data/lecture_models.dart';
import '../services/assignment_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'lecture_page.dart';

class StudentAssignmentsPage extends StatefulWidget {
  const StudentAssignmentsPage({super.key});

  @override
  State<StudentAssignmentsPage> createState() => _StudentAssignmentsPageState();
}

class _StudentAssignmentsPageState extends State<StudentAssignmentsPage> {
  final AssignmentService _service = AssignmentService();
  bool _loading = true;
  String? _error;
  List<AssignmentItem> _active = const [];
  List<AssignmentItem> _completed = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.fetchStudentAssignments();
      if (!mounted) return;
      setState(() {
        _active = result.active;
        _completed = result.completed;
        _loading = false;
      });
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
    }
  }

  Future<void> _start(AssignmentItem item) async {
    try {
      final opened = await _service.openAssignment(item.assignmentId);
      if (!mounted) return;
      final section = CurriculumSection(
        id: opened.sectionId,
        number: opened.sectionLabel,
        title: opened.sectionLabel,
        label: opened.sectionLabel,
        type: 'lesson',
        contentStatus: 'available',
        v1Launch: true,
      );
      final override = LectureQuestion(
        questionId: opened.questionId,
        sectionId: opened.sectionId,
        sectionLabel: opened.sectionLabel,
        prompt: opened.questionPrompt,
        hint: opened.note.isNotEmpty ? opened.note : '这是家长布置的作业，请完整讲清思路。',
        referenceSteps: const ['写出已知', '列出关键步骤', '总结易错点'],
        difficulty: opened.difficulty,
        tags: opened.sourceType == 'custom' ? const ['家长自定义'] : const ['家长布置'],
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LecturePage(
            section: section,
            initialQuestionId: opened.questionId,
            questionOverride: override,
            assignmentId: opened.assignmentId,
          ),
        ),
      );
      await _load();
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: '我的作业',
      actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _active.isEmpty && _completed.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _active.isEmpty && _completed.isEmpty) {
      return Center(child: Text(_error!, style: const TextStyle(color: AppPalette.error)));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          if (_active.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('目前没有待完成的作业，继续保持！')),
            )
          else ...[
            Text('待完成', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._active.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                child: _AssignmentTile(item: item, onStart: () => _start(item)),
              ),
            ),
          ],
          if (_completed.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.moduleGap),
            Text('最近完成', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._completed.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                child: _AssignmentTile(item: item, completed: true),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  const _AssignmentTile({required this.item, this.onStart, this.completed = false});

  final AssignmentItem item;
  final VoidCallback? onStart;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final overdue = item.status == 'overdue';
    return StudyPanel(
      tone: overdue ? StudyPanelTone.danger : StudyPanelTone.surface,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(item.sectionLabel, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          FormulaText(item.questionPrompt, style: Theme.of(context).textTheme.bodyMedium),
          if (item.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('家长说：${item.note}', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          Text(
            overdue ? '已逾期 · 截止 ${_fmt(item.dueAt)}' : '请在 ${_fmt(item.dueAt)} 前完成',
            style: TextStyle(
              color: overdue ? AppPalette.error : AppPalette.textSecondary,
              fontSize: 13,
            ),
          ),
          if (!completed && onStart != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: onStart, child: const Text('开始讲题')),
          ],
        ],
      ),
    );
  }

  String _fmt(DateTime d) {
    final local = d.toLocal();
    return '${local.month}月${local.day}日 ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
  }
}
