import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/assignment_models.dart';
import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../services/assignment_service.dart';
import '../services/parent_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';

class ParentAssignCreatePage extends StatefulWidget {
  const ParentAssignCreatePage({super.key});

  @override
  State<ParentAssignCreatePage> createState() => _ParentAssignCreatePageState();
}

class _ParentAssignCreatePageState extends State<ParentAssignCreatePage> {
  final AssignmentService _service = AssignmentService();
  final ParentService _parentService = ParentService();
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  final _promptController = TextEditingController();

  late final Future<MathCurriculum> _curriculumFuture =
      CurriculumRepository.instance.load();

  String _mode = 'catalog';
  String? _sectionId;
  int _difficulty = 1;
  String? _selectedQuestionId;
  DateTime _dueAt = DateTime.now().add(const Duration(hours: 24));
  bool _submitting = false;
  String? _error;
  RecognizedQuestion? _recognized;
  List<AssignmentRecommendation> _recommendations = const [];
  bool _loadingRecommendations = true;
  String? _recommendationsError;
  String _childGrade = '八年级';

  @override
  void initState() {
    super.initState();
    _loadChildGrade();
    _loadRecommendations();
  }

  Future<void> _loadChildGrade() async {
    try {
      final dashboard = await _parentService.fetchDashboard();
      if (!mounted) return;
      setState(() {
        _childGrade =
            dashboard.grade.trim().isEmpty ? '八年级' : dashboard.grade.trim();
        _sectionId = null;
      });
    } catch (_) {
      /* 看板失败时保留八年级兜底，提交时后端仍会校验孩子年级。 */
    }
  }

  Future<void> _loadRecommendations() async {
    setState(() {
      _loadingRecommendations = true;
      _recommendationsError = null;
    });
    try {
      final items = await _service.fetchRecommendations();
      if (!mounted) return;
      setState(() {
        _recommendations = items;
        _loadingRecommendations = false;
      });
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _recommendationsError = e.userMessage;
        _loadingRecommendations = false;
      });
    }
  }

  void _applyRecommendation(AssignmentRecommendation item) {
    setState(() {
      _mode = 'catalog';
      _sectionId = item.sectionId;
      _difficulty = item.difficulty;
      _selectedQuestionId = item.questionId;
      _recognized = null;
      _error = null;
      if (_titleController.text.trim().isEmpty) {
        _titleController.text =
            '${item.sectionLabel} · ${item.difficultyLabel}巩固';
      }
      if (_noteController.text.trim().isEmpty) {
        _noteController.text = item.reason;
      }
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已选用推荐题：${item.sectionLabel}')));
  }

  @override
  void dispose() {
    _service.close();
    _parentService.close();
    _titleController.dispose();
    _noteController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
      initialDate: _dueAt,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await _service.recognizeImage(File(picked.path));
      if (!mounted) return;
      setState(() {
        _recognized = result;
        _mode = 'custom';
        _sectionId =
            result.sectionId != 'unknown' ? result.sectionId : _sectionId;
        _promptController.text = result.questionPrompt;
        _submitting = false;
      });
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _submitting = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_sectionId == null || _sectionId!.isEmpty) {
      setState(() => _error = '请选择小节。');
      return;
    }
    if (_mode == 'custom' && _promptController.text.trim().length < 4) {
      setState(() => _error = '请填写或识别题面。');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _service.createAssignment(
        sourceType: _mode,
        sectionId: _sectionId!,
        dueAt: _dueAt.toUtc(),
        difficulty: _difficulty,
        questionId: _mode == 'catalog' ? (_selectedQuestionId ?? '') : '',
        questionPrompt: _promptController.text.trim(),
        title: _titleController.text.trim(),
        note: _noteController.text.trim(),
        knowledgeTags: _recognized?.knowledgeTags ?? const [],
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AssignmentApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: '布置作业',
      child: FutureBuilder<MathCurriculum>(
        future: _curriculumFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final curriculum = snapshot.data!;
          final sections = curriculum.books
              .where((b) => b.gradeLabel == _childGrade)
              .expand((b) => b.chapters)
              .expand((c) => c.sections)
              .toList(growable: false);
          if (sections.isNotEmpty &&
              (_sectionId == null ||
                  !sections.any((s) => s.id == _sectionId))) {
            _sectionId = sections.first.id;
            _selectedQuestionId = null;
          } else if (sections.isEmpty) {
            _sectionId = null;
            _selectedQuestionId = null;
          }

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _RecommendationsPanel(
                loading: _loadingRecommendations,
                error: _recommendationsError,
                items: _recommendations,
                selectedQuestionId: _selectedQuestionId,
                onRetry: _loadRecommendations,
                onSelect: _applyRecommendation,
              ),
              const SizedBox(height: AppSpacing.moduleGap),
              Text(
                '当前孩子年级：$_childGrade',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'catalog',
                    label: Text('小节+难度'),
                    icon: Icon(Icons.menu_book_outlined),
                  ),
                  ButtonSegment(
                    value: 'custom',
                    label: Text('上传题目'),
                    icon: Icon(Icons.photo_camera_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: AppSpacing.moduleGap),
              DropdownButtonFormField<String>(
                initialValue: _sectionId,
                decoration: const InputDecoration(
                  labelText: '选择小节',
                  border: OutlineInputBorder(),
                ),
                items: sections
                    .map(
                      (s) =>
                          DropdownMenuItem(value: s.id, child: Text(s.label)),
                    )
                    .toList(growable: false),
                onChanged:
                    (v) => setState(() {
                      _sectionId = v;
                      _selectedQuestionId = null;
                    }),
              ),
              if (_selectedQuestionId != null && _mode == 'catalog') ...[
                const SizedBox(height: 8),
                Text(
                  '已选用推荐题（${_selectedQuestionId!}），将布置指定题目而非随机难度题。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppPalette.primary),
                ),
              ],
              if (_mode == 'catalog') ...[
                const SizedBox(height: AppSpacing.itemGap),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '题目难度',
                    border: OutlineInputBorder(),
                  ),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('基础')),
                      ButtonSegment(value: 2, label: Text('巩固')),
                      ButtonSegment(value: 3, label: Text('挑战')),
                    ],
                    selected: {_difficulty},
                    onSelectionChanged:
                        (s) => setState(() {
                          _difficulty = s.first;
                          _selectedQuestionId = null;
                        }),
                  ),
                ),
              ] else ...[
                const SizedBox(height: AppSpacing.itemGap),
                OutlinedButton.icon(
                  onPressed: _submitting ? null : _pickImage,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('从相册上传题目照片'),
                ),
                const SizedBox(height: AppSpacing.itemGap),
                TextField(
                  controller: _promptController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '题面（可编辑）',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                if (_promptController.text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  FormulaText(
                    _promptController.text,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ],
              const SizedBox(height: AppSpacing.itemGap),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '作业标题（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.itemGap),
              TextField(
                controller: _noteController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '给孩子留言（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.itemGap),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('截止时间'),
                subtitle: Text(_fmtDue(_dueAt)),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: _pickDue,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: AppPalette.error)),
              ],
              const SizedBox(height: AppSpacing.moduleGap),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child:
                    _submitting
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text('布置给孩子'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _fmtDue(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _RecommendationsPanel extends StatelessWidget {
  const _RecommendationsPanel({
    required this.loading,
    required this.error,
    required this.items,
    required this.selectedQuestionId,
    required this.onRetry,
    required this.onSelect,
  });

  final bool loading;
  final String? error;
  final List<AssignmentRecommendation> items;
  final String? selectedQuestionId;
  final VoidCallback onRetry;
  final void Function(AssignmentRecommendation item) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StudyPanel(
      tone: StudyPanelTone.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_outlined,
                size: 18,
                color: AppPalette.primary,
              ),
              const SizedBox(width: 6),
              Text('智能推荐', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (!loading)
                TextButton(onPressed: onRetry, child: const Text('刷新')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '根据孩子的易错回顾、掌握薄弱小节与未完成讲题推荐题目',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (error != null)
            Text(error!, style: const TextStyle(color: AppPalette.error))
          else if (items.isEmpty)
            Text(
              '暂无推荐，可先手动选小节布置；孩子讲题后会根据弱项自动推荐。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            )
          else
            ...items.map((item) {
              final selected = selectedQuestionId == item.questionId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color:
                      selected
                          ? AppPalette.primary.withValues(alpha: 0.08)
                          : AppPalette.surfaceElevated,
                  borderRadius: AppRadius.cardR,
                  child: InkWell(
                    borderRadius: AppRadius.cardR,
                    onTap: () => onSelect(item),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.sectionLabel,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppPalette.primary.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  item.difficultyLabel,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: AppPalette.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (item.knowledgePointLabel.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              item.knowledgePointLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppPalette.textSecondary,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            item.reason,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppPalette.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (item.masteryScore != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '当前掌握度 ${item.masteryScore}/100',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppPalette.textSecondary,
                              ),
                            ),
                          ],
                          if (item.questionPrompt.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            FormulaText(
                              item.questionPrompt,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              selected ? '已选用' : '选用此题',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: AppPalette.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
