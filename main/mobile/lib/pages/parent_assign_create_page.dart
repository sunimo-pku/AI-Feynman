import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/assignment_models.dart';
import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../services/assignment_service.dart';
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
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  final _promptController = TextEditingController();

  late final Future<MathCurriculum> _curriculumFuture = CurriculumRepository.instance.load();

  String _mode = 'catalog';
  String? _sectionId;
  int _difficulty = 1;
  DateTime _dueAt = DateTime.now().add(const Duration(hours: 24));
  bool _submitting = false;
  String? _error;
  RecognizedQuestion? _recognized;

  @override
  void dispose() {
    _service.close();
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
      _dueAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
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
        _sectionId = result.sectionId != 'unknown' ? result.sectionId : _sectionId;
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
              .expand((b) => b.chapters)
              .expand((c) => c.sections)
              .toList(growable: false);
          _sectionId ??= sections.firstWhere((s) => s.isAvailable, orElse: () => sections.first).id;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'catalog', label: Text('小节+难度'), icon: Icon(Icons.menu_book_outlined)),
                  ButtonSegment(value: 'custom', label: Text('上传题目'), icon: Icon(Icons.photo_camera_outlined)),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: AppSpacing.moduleGap),
              DropdownButtonFormField<String>(
                initialValue: _sectionId,
                decoration: const InputDecoration(labelText: '选择小节', border: OutlineInputBorder()),
                items: sections
                    .map((s) => DropdownMenuItem(value: s.id, child: Text(s.label)))
                    .toList(growable: false),
                onChanged: (v) => setState(() => _sectionId = v),
              ),
              if (_mode == 'catalog') ...[
                const SizedBox(height: AppSpacing.itemGap),
                InputDecorator(
                  decoration: const InputDecoration(labelText: '题目难度', border: OutlineInputBorder()),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('基础')),
                      ButtonSegment(value: 2, label: Text('巩固')),
                      ButtonSegment(value: 3, label: Text('挑战')),
                    ],
                    selected: {_difficulty},
                    onSelectionChanged: (s) => setState(() => _difficulty = s.first),
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
                  FormulaText(_promptController.text, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
              const SizedBox(height: AppSpacing.itemGap),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: '作业标题（可选）', border: OutlineInputBorder()),
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
                child: _submitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
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
