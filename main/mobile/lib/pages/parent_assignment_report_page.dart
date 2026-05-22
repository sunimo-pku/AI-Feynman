import 'package:flutter/material.dart';

import '../data/assignment_models.dart';
import '../services/assignment_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';

class ParentAssignmentReportPage extends StatefulWidget {
  const ParentAssignmentReportPage({super.key, required this.assignmentId});

  final String assignmentId;

  @override
  State<ParentAssignmentReportPage> createState() => _ParentAssignmentReportPageState();
}

class _ParentAssignmentReportPageState extends State<ParentAssignmentReportPage> {
  final AssignmentService _service = AssignmentService();
  bool _loading = true;
  String? _error;
  AssignmentReport? _report;

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
      final report = await _service.fetchReport(widget.assignmentId);
      if (!mounted) return;
      setState(() {
        _report = report;
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

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: '作业完成报告',
      actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: AppPalette.error)));
    }
    final r = _report!;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.pageEdge),
      children: [
        _ReportHeader(report: r),
        const SizedBox(height: AppSpacing.moduleGap),
        _ReportSection(
          title: '讲题摘要',
          child: r.summary.isEmpty
              ? const Text('暂无摘要，孩子可能尚未同步回顾。')
              : FormulaText(r.summary, style: Theme.of(context).textTheme.bodyLarge),
        ),
        if (r.agentHighlights.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.moduleGap),
          _ReportSection(
            title: 'AI 追问亮点',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: r.agentHighlights
                  .map((t) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FormulaText('• $t', style: Theme.of(context).textTheme.bodyMedium),
                      ))
                  .toList(growable: false),
            ),
          ),
        ],
        if (r.cautionPoints.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.moduleGap),
          _ReportSection(
            title: '易错提醒',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: r.cautionPoints
                  .map((t) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FormulaText('• $t', style: Theme.of(context).textTheme.bodyMedium),
                      ))
                  .toList(growable: false),
            ),
          ),
        ],
        if (r.transcriptText.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.moduleGap),
          _ReportSection(
            title: '孩子口述摘录',
            child: Text(r.transcriptText, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
        if (r.turns.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.moduleGap),
          _ReportSection(
            title: '多 Agent 讨论记录',
            child: Column(
              children: r.turns
                  .map(
                    (turn) => Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.background,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: AppShadows.paper,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            turn['displayName']?.toString() ?? turn['role']?.toString() ?? 'AI',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          FormulaText(
                            turn['text']?.toString() ?? '',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ],
    );
  }
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({required this.report});

  final AssignmentReport report;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppShadows.paper,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(report.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(report.sectionLabel, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          FormulaText(report.questionPrompt, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Chip(
                label: report.onTime ? '按时完成' : '逾期完成',
                color: report.onTime ? const Color(0xFF047857) : AppPalette.error,
              ),
              _Chip(label: '追问 ${report.roundCount} 轮', color: AppPalette.primary),
              _Chip(label: '掌握度 +${report.masteryDelta}', color: AppPalette.primaryAccent),
            ],
          ),
          if (report.completedAt != null) ...[
            const SizedBox(height: 10),
            Text(
              '完成时间：${_fmt(report.completedAt!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (report.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('家长留言：${report.note}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  String _fmt(DateTime d) => '${d.month}月${d.day}日 ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

class _ReportSection extends StatelessWidget {
  const _ReportSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppShadows.paper,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
