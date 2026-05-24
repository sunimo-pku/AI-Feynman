import 'dart:async';

import 'package:flutter/material.dart';

import '../data/round12_models.dart';
import '../services/replay_service.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'replay_page.dart';

class PublicReplaysPage extends StatefulWidget {
  const PublicReplaysPage({
    super.key,
    this.embeddedInTab = false,
    this.sectionId,
    this.questionId,
    this.title = '讲题广场',
  });

  final bool embeddedInTab;
  final String? sectionId;
  final String? questionId;
  final String title;

  @override
  State<PublicReplaysPage> createState() => _PublicReplaysPageState();
}

class _PublicReplaysPageState extends State<PublicReplaysPage> {
  final ReplayService _service = ReplayService();
  late Future<List<ReplaySummary>> _future = _fetch();

  Future<List<ReplaySummary>> _fetch() {
    return _service.fetchPublicReplays(
      sectionId: widget.sectionId,
      questionId: widget.questionId,
    );
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  void _reload() {
    setState(() => _future = _fetch());
  }

  Future<void> _toggleLike(ReplaySummary replay) async {
    final nextLiked = !replay.likedByMe;
    try {
      final updated = await _service.setReplayLiked(
        replay: replay,
        liked: nextLiked,
      );
      if (!mounted) return;
      setState(() {
        _future = _future.then(
          (items) => items
              .map(
                (item) => item.sessionId == replay.sessionId ? updated : item,
              )
              .toList(growable: false),
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('点赞失败：$e')));
    }
  }

  Future<void> _openReplay(ReplaySummary replay) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReplayPage(sessionId: replay.sessionId),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder<List<ReplaySummary>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          if (snapshot.hasError) {
            return _ErrorState(message: '${snapshot.error}', onRetry: _reload);
          }
          return const Center(child: CircularProgressIndicator());
        }
        final replays = snapshot.data!;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.pageEdge,
              widget.embeddedInTab ? 12 : AppSpacing.pageEdge,
              AppSpacing.pageEdge,
              24,
            ),
            children: [
              StudyPanel(
                tone: StudyPanelTone.primary,
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: SectionHeader(
                  title: widget.title,
                  subtitle:
                      widget.questionId == null
                          ? '像看短视频一样看看别人怎么讲题，也给讲得好的同学点个赞。'
                          : '同一道题里，老师讲解置顶；同学讲法按点赞数从高到低排列。',
                  accent: AppPalette.primaryAccent,
                  action: IconButton(
                    tooltip: '刷新',
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (replays.isEmpty)
                const StudyEmptyHint('还没有同学发布讲题视频。完成一次讲题后，可以把自己的讲法发出来。')
              else
                ...replays.map(
                  (replay) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PublicReplayCard(
                      replay: replay,
                      onTap: () => unawaited(_openReplay(replay)),
                      onLike: () => unawaited(_toggleLike(replay)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );

    if (widget.embeddedInTab) {
      return body;
    }
    return StudyShell(title: widget.title, child: body);
  }
}

class _PublicReplayCard extends StatelessWidget {
  const _PublicReplayCard({
    required this.replay,
    required this.onTap,
    required this.onLike,
  });

  final ReplaySummary replay;
  final VoidCallback onTap;
  final VoidCallback onLike;

  static String _durationLabel(int ms) {
    final sec = ms <= 0 ? 0 : (ms / 1000).ceil();
    final m = sec ~/ 60;
    final s = sec % 60;
    return m > 0 ? '$m 分 $s 秒' : '$s 秒';
  }

  static String _difficultyLabel(int d) {
    if (d >= 3) return '挑战';
    if (d >= 2) return '巩固';
    return '基础';
  }

  @override
  Widget build(BuildContext context) {
    final title =
        replay.sectionLabel.isNotEmpty ? replay.sectionLabel : replay.sectionId;
    final description = replay.description.trim();
    return StudyPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ReplayAuthorAvatar(replay: replay),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              replay.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 6),
                          StudySoftTag(
                            text: replay.authorRankTier,
                            accent: AppPalette.primaryAccent,
                          ),
                          if (replay.isMine) ...[
                            const SizedBox(width: 6),
                            const StudySoftTag(
                              text: '我发布的',
                              accent: AppPalette.primary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_difficultyLabel(replay.difficulty)} · ${_durationLabel(replay.durationMs)} · MP4',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: replay.likedByMe ? '取消点赞' : '点赞',
                  onPressed: onLike,
                  icon: Icon(
                    replay.likedByMe ? Icons.favorite : Icons.favorite_border,
                    color:
                        replay.likedByMe
                            ? AppPalette.error
                            : AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.favorite,
                  size: 16,
                  color:
                      replay.likeCount > 0
                          ? AppPalette.error
                          : AppPalette.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '${replay.likeCount} 个赞',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '看视频',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: AppPalette.primary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplayAuthorAvatar extends StatelessWidget {
  const _ReplayAuthorAvatar({required this.replay});

  final ReplaySummary replay;

  @override
  Widget build(BuildContext context) {
    final initial =
        replay.authorInitial.trim().isEmpty
            ? (replay.authorName.trim().isEmpty
                ? '同'
                : replay.authorName.trim().substring(0, 1))
            : replay.authorInitial.trim();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppPalette.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Text(
        initial.substring(0, 1),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: AppPalette.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        child: StudyPanel(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('讲题广场加载失败', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('再试一次')),
            ],
          ),
        ),
      ),
    );
  }
}
