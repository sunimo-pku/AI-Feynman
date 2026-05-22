import 'package:flutter/material.dart';

import '../data/assignment_models.dart';
import '../services/assignment_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'parent_assign_create_page.dart';
import 'parent_assignment_report_page.dart';

class ParentAssignmentsPage extends StatefulWidget {
  const ParentAssignmentsPage({super.key});

  @override
  State<ParentAssignmentsPage> createState() => _ParentAssignmentsPageState();
}

class _ParentAssignmentsPageState extends State<ParentAssignmentsPage> {
  final AssignmentService _service = AssignmentService();
  bool _loading = true;
  String? _error;
  List<AssignmentItem> _items = const [];
  int _pendingCount = 0;

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
      final result = await _service.fetchParentAssignments();
      if (!mounted) return;
      setState(() {
        _items = result.assignments;
        _pendingCount = result.pendingCount;
        _loading = false;
      });
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _onCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ParentAssignCreatePage()),
    );
    if (created == true) {
      await _load();
    }
  }

  Future<void> _onDelete(AssignmentItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销作业'),
        content: Text('确定撤销「${item.title}」吗？孩子将无法再看到这条待办。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteAssignment(item.assignmentId);
      await _load();
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: '家长端 · 作业',
      maxWidth: 1180,
      actions: [
        IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
        IconButton(tooltip: '布置作业', icon: const Icon(Icons.add_circle_outline), onPressed: _onCreate),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppPalette.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          _SummaryStrip(pending: _pendingCount, total: _items.length),
          const SizedBox(height: AppSpacing.moduleGap),
          if (_items.isEmpty)
            const _EmptyAssignments()
          else
            ..._items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                child: _AssignmentCard(
                  item: item,
                  onReport: item.status == 'completed'
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ParentAssignmentReportPage(assignmentId: item.assignmentId),
                            ),
                          )
                      : null,
                  onDelete: item.status == 'completed' ? null : () => _onDelete(item),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.pending, required this.total});

  final int pending;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('待完成 $pending 项', style: Theme.of(context).textTheme.titleMedium),
                Text('共布置 $total 项作业', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Icon(Icons.schedule, color: AppPalette.primaryAccent),
        ],
      ),
    );
  }
}

class _EmptyAssignments extends StatelessWidget {
  const _EmptyAssignments();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        children: [
          Icon(Icons.assignment_outlined, size: 48, color: AppPalette.textSecondary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text('还没有布置过作业', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点右下角「布置作业」，从弱项小节或拍照上传题目开始。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({required this.item, this.onReport, this.onDelete});

  final AssignmentItem item;
  final VoidCallback? onReport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final status = _statusMeta(item.status);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(item.title, style: Theme.of(context).textTheme.titleMedium)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: status.bg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(status.label, style: TextStyle(color: status.fg, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(item.sectionLabel, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          FormulaText(item.questionPrompt, style: Theme.of(context).textTheme.bodyMedium),
          if (item.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('留言：${item.note}', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          Text(
            '截止 ${_fmtDate(item.dueAt.toLocal())}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
          ),
          if (item.completionSummary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('完成摘要：${item.completionSummary}', maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (onReport != null)
                FilledButton.tonal(onPressed: onReport, child: const Text('查看完成报告')),
              if (onDelete != null) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: onDelete, child: const Text('撤销')),
              ],
            ],
          ),
        ],
      ),
    );
  }

  ({String label, Color bg, Color fg}) _statusMeta(String status) {
    switch (status) {
      case 'completed':
        return (label: '已完成', bg: const Color(0xFFD1FAE5), fg: const Color(0xFF047857));
      case 'overdue':
        return (label: '已逾期', bg: const Color(0xFFFEE2E2), fg: AppPalette.error);
      case 'in_progress':
        return (label: '进行中', bg: const Color(0xFFDBEAFE), fg: AppPalette.primary);
      default:
        return (label: '待完成', bg: const Color(0xFFFEF3C7), fg: const Color(0xFFB45309));
    }
  }
}

String _fmtDate(DateTime d) {
  return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
