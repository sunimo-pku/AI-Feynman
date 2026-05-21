import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'lecture_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Future<MathCurriculum> _curriculumFuture =
      CurriculumRepository.instance.load();
  bool? _apiHealthy;

  @override
  void initState() {
    super.initState();
    _checkApi();
  }

  Future<void> _checkApi() async {
    final ok = await ApiService().checkHealth();
    if (mounted) setState(() => _apiHealthy = ok);
  }

  void _onSectionTap(CurriculumSection section) {
    if (section.isAvailable) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LecturePage(section: section),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('该章节内容制作中，请先体验「八年级下册 · 第十六章 二次根式」。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: const Text('AI 费曼 · 初中数学自习室'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _ApiStatusBadge(healthy: _apiHealthy)),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<MathCurriculum>(
          future: _curriculumFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('目录加载失败：${snapshot.error}'));
            }
            final curriculum = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.pageEdge),
              children: [
                _HeroBanner(curriculum: curriculum),
                const SizedBox(height: AppSpacing.moduleGap),
                ...curriculum.books.map(
                  (book) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                    child: _BookCard(book: book, onSectionTap: _onSectionTap),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({required this.curriculum});

  final MathCurriculum curriculum;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 22,
                decoration: BoxDecoration(
                  color: AppPalette.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${curriculum.publisher} · ${curriculum.stageLabel}${curriculum.subjectLabel}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'V1 仅开放「八年级下册 · 第十六章 二次根式」。其余章节正在备课，目录可以浏览，暂未开放练习。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _Tag(label: '今日开放：二次根式', color: AppPalette.primary, filled: true),
              _Tag(label: '16.1 二次根式', color: AppPalette.primaryAccent),
              _Tag(label: '16.2 乘除', color: AppPalette.primaryAccent),
              _Tag(label: '16.3 加减', color: AppPalette.primaryAccent),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    this.filled = false,
  });

  final String label;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: filled ? Colors.white : color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ApiStatusBadge extends StatelessWidget {
  const _ApiStatusBadge({required this.healthy});

  final bool? healthy;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (healthy) {
      true => ('API 已连接', AppPalette.primaryAccent),
      false => ('API 未连接', AppPalette.error),
      null => ('检测中…', AppPalette.textSecondary),
    };
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

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onSectionTap,
  });

  final CurriculumBook book;
  final ValueChanged<CurriculumSection> onSectionTap;

  @override
  Widget build(BuildContext context) {
    final hasAvailable = book.chapters
        .any((c) => c.sections.any((s) => s.isAvailable));
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: hasAvailable,
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          title: Text(
            book.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasAvailable
                  ? 'V1 已开放章节'
                  : '即将上线',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: hasAvailable
                        ? AppPalette.primaryAccent
                        : AppPalette.comingSoon,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          children: book.chapters.map((chapter) {
            return _ChapterBlock(chapter: chapter, onSectionTap: onSectionTap);
          }).toList(),
        ),
      ),
    );
  }
}

class _ChapterBlock extends StatelessWidget {
  const _ChapterBlock({
    required this.chapter,
    required this.onSectionTap,
  });

  final CurriculumChapter chapter;
  final ValueChanged<CurriculumSection> onSectionTap;

  @override
  Widget build(BuildContext context) {
    final chapterAvailable = chapter.sections.any((s) => s.isAvailable);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                chapter.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: chapterAvailable
                          ? AppPalette.textPrimary
                          : AppPalette.comingSoon,
                    ),
              ),
              if (!chapterAvailable) ...[
                const SizedBox(width: 8),
                const Icon(Icons.lock_outline,
                    size: 14, color: AppPalette.comingSoon),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chapter.sections
                .map((s) => _SectionPill(section: s, onTap: onSectionTap))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _SectionPill extends StatelessWidget {
  const _SectionPill({
    required this.section,
    required this.onTap,
  });

  final CurriculumSection section;
  final ValueChanged<CurriculumSection> onTap;

  @override
  Widget build(BuildContext context) {
    final available = section.isAvailable;
    final bg = available
        ? AppPalette.primary.withValues(alpha: 0.08)
        : AppPalette.comingSoon.withValues(alpha: 0.08);
    final border = available
        ? AppPalette.primary.withValues(alpha: 0.4)
        : AppPalette.outline;
    final textColor = available ? AppPalette.primary : AppPalette.comingSoon;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchMin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap: () => onTap(section),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.buttonR,
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  available ? Icons.play_circle_outline : Icons.lock_outline,
                  size: 18,
                  color: textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  section.label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: available
                        ? AppPalette.primaryAccent.withValues(alpha: 0.15)
                        : AppPalette.comingSoon.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    available ? '可练习' : '即将上线',
                    style: TextStyle(
                      color: available
                          ? AppPalette.primaryAccent
                          : AppPalette.comingSoon,
                      fontSize: 11,
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
  }
}
