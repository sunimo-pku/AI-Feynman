import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../config/api_config.dart';
import '../data/lecture_models.dart';
import '../data/round12_models.dart';
import '../services/replay_service.dart';
import '../theme/app_theme.dart';
import '../utils/pcm_wav.dart';
import '../widgets/agent_message_bubble.dart';
import '../widgets/formula_text.dart';
import '../widgets/replay_ink_canvas.dart';
import '../widgets/study_layout.dart';

class ReplayPage extends StatefulWidget {
  const ReplayPage({super.key, required this.sessionId, this.studentId});

  final String sessionId;
  final int? studentId;

  @override
  State<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends State<ReplayPage> {
  final _service = ReplayService();
  final _player = AudioPlayer();

  Map<String, dynamic>? _payload;
  String? _error;
  bool _playing = false;
  bool _seeking = false;
  int _positionMs = 0;
  int _durationMs = 0;
  int _likeCount = 0;
  bool _likedByMe = false;
  Uint8List? _wavBytes;
  List<ReplayComment> _comments = const [];
  bool _commentsLoading = false;
  final TextEditingController _commentController = TextEditingController();
  Timer? _fallbackTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _service.fetchReplay(
        widget.sessionId,
        studentId: widget.studentId,
      );
      if (!mounted) return;
      final ink = (p['inkTimeline'] as List?) ?? const [];
      final turns = (p['turnsTimeline'] as List?) ?? const [];
      final pcm = decodeReplayPcmChunks(
        (p['audioBase64Chunks'] as List?) ?? const [],
      );
      final audioMs = pcm16DurationMs(pcm);
      final wav = pcm.isEmpty ? null : pcm16MonoToWav(pcm);
      final duration = replayTimelineMaxMs(
        inkTimeline: ink,
        turnsTimeline: turns,
        storedDurationMs: (p['durationMs'] as num?)?.toInt() ?? 0,
        audioDurationMs: audioMs,
      );
      setState(() {
        _payload = p;
        _durationMs = duration;
        _likeCount = (p['likeCount'] as num?)?.toInt() ?? 0;
        _likedByMe = p['likedByMe'] == true;
        _wavBytes = wav;
      });
      _bindPlayerEvents();
      if (p['isPublic'] == true) {
        unawaited(_loadComments());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _bindPlayerEvents() {
    _posSub?.cancel();
    _completeSub?.cancel();
    _posSub = _player.onPositionChanged.listen((pos) {
      if (!mounted || _seeking || !_playing) return;
      setState(() => _positionMs = pos.inMilliseconds.clamp(0, _durationMs));
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _positionMs = _durationMs;
      });
      _fallbackTimer?.cancel();
    });
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _pause();
      return;
    }
    await _playFrom(_positionMs >= _durationMs ? 0 : _positionMs);
  }

  Future<void> _playFrom(int ms) async {
    final wav = _wavBytes;
    if (wav != null && wav.isNotEmpty) {
      await _player.stop();
      await _player.setVolume(1);
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'));
      if (ms > 0) {
        await _player.seek(Duration(milliseconds: ms));
      }
      setState(() {
        _playing = true;
        _positionMs = ms;
      });
      return;
    }
    setState(() {
      _playing = true;
      _positionMs = ms;
    });
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_playing) return;
      setState(() {
        _positionMs += 100;
        if (_positionMs >= _durationMs) {
          _positionMs = _durationMs;
          _playing = false;
          _fallbackTimer?.cancel();
        }
      });
    });
  }

  Future<void> _pause() async {
    _fallbackTimer?.cancel();
    if (_wavBytes != null) {
      await _player.pause();
    }
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _seekTo(int ms) async {
    final clamped = ms.clamp(0, _durationMs);
    setState(() => _positionMs = clamped);
    if (_playing && _wavBytes != null) {
      await _player.seek(Duration(milliseconds: clamped));
    }
  }

  Future<void> _toggleLike() async {
    final p = _payload;
    if (p == null) return;
    final replay = ReplaySummary.fromJson(p);
    final nextLiked = !_likedByMe;
    try {
      final updated = await _service.setReplayLiked(
        replay: replay,
        liked: nextLiked,
      );
      if (!mounted) return;
      setState(() {
        _likedByMe = updated.likedByMe;
        _likeCount = updated.likeCount;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('点赞失败：$e')));
    }
  }

  Future<void> _loadComments() async {
    final p = _payload;
    if (p == null) return;
    setState(() => _commentsLoading = true);
    try {
      final comments = await _service.fetchComments(
        p['sessionId'] as String? ?? widget.sessionId,
      );
      if (!mounted) return;
      setState(() {
        _comments = comments;
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsLoading = false);
    }
  }

  Future<void> _submitComment() async {
    final p = _payload;
    if (p == null) return;
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    try {
      final comment = await _service.postComment(
        sessionId: p['sessionId'] as String? ?? widget.sessionId,
        body: body,
      );
      if (!mounted) return;
      _commentController.clear();
      setState(() => _comments = [comment, ..._comments]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('评论失败：$e')));
    }
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _posSub?.cancel();
    _completeSub?.cancel();
    _commentController.dispose();
    unawaited(_player.dispose());
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final canLike = p != null && p['isPublic'] == true;
    final videoUrl = p == null ? '' : (p['videoUrl'] as String? ?? '').trim();
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: const Text('讲题视频'),
        actions: [
          TextButton.icon(
            onPressed: canLike ? () => unawaited(_toggleLike()) : null,
            icon: Icon(
              _likedByMe ? Icons.favorite : Icons.favorite_border,
              color: _likedByMe ? AppPalette.error : AppPalette.primary,
            ),
            label: Text('$_likeCount'),
          ),
        ],
      ),
      body: SafeArea(
        child:
            p == null
                ? Center(child: Text(_error ?? '加载中…'))
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.pageEdge,
                          AppSpacing.pageEdge,
                          AppSpacing.pageEdge,
                          8,
                        ),
                        children: [
                          FormulaText(
                            p['questionPrompt'] as String? ?? '暂无题面',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (canLike) ...[
                            const SizedBox(height: 10),
                            _ReplayAuthorHeader(
                              authorName: p['authorName'] as String? ?? '同学',
                              authorInitial:
                                  p['authorInitial'] as String? ?? '同',
                              rankTier: p['authorRankTier'] as String? ?? '青铜',
                              isMine: p['isMine'] == true,
                            ),
                          ],
                          if ((p['description'] as String? ?? '')
                              .trim()
                              .isNotEmpty) ...[
                            const SizedBox(height: 10),
                            StudyPanel(
                              tone: StudyPanelTone.quiet,
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                10,
                                14,
                                10,
                              ),
                              child: Text(
                                p['description'] as String,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (videoUrl.isNotEmpty)
                            _ReplayMp4Player(videoUrl: videoUrl)
                          else ...[
                            AspectRatio(
                              aspectRatio: 4 / 3,
                              child: ReplayInkCanvas(
                                frame: replayInkFrameAt(
                                  (p['inkTimeline'] as List?) ?? const [],
                                  _positionMs,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _ReplayTransportBar(
                              playing: _playing,
                              positionMs: _positionMs,
                              durationMs: _durationMs,
                              hasAudio:
                                  _wavBytes != null && _wavBytes!.isNotEmpty,
                              onPlayPause: () => unawaited(_togglePlay()),
                              onSeekStart: () => _seeking = true,
                              onSeekEnd: (v) {
                                _seeking = false;
                                unawaited(_seekTo(v.round()));
                              },
                              onSeekChanged: (v) {
                                setState(() => _positionMs = v.round());
                              },
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '同伴发言',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            ..._buildTurnBubbles(p),
                          ],
                          if (canLike) ...[
                            const SizedBox(height: 18),
                            _ReplayCommentsPanel(
                              controller: _commentController,
                              comments: _comments,
                              loading: _commentsLoading,
                              onSubmit: () => unawaited(_submitComment()),
                              onRefresh: () => unawaited(_loadComments()),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
      ),
    );
  }

  List<Widget> _buildTurnBubbles(Map<String, dynamic> p) {
    final turns = replayTurnsVisibleAt(
      (p['turnsTimeline'] as List?) ?? const [],
      _positionMs,
    );
    if (turns.isEmpty) {
      return [
        Text(
          '播放到对应时刻后，小明、大雄和班长的发言会出现在这里。',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
        ),
      ];
    }
    return turns.map((t) {
      final role = parseAgentRole(t['role'] as String? ?? '');
      if (role == AgentRole.system) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AgentMessageBubble(
          turn: AgentTurn(
            role: role,
            displayName: t['displayName'] as String? ?? '同伴',
            text: t['text'] as String? ?? '',
          ),
        ),
      );
    }).toList();
  }
}

class _ReplayAuthorHeader extends StatelessWidget {
  const _ReplayAuthorHeader({
    required this.authorName,
    required this.authorInitial,
    required this.rankTier,
    required this.isMine,
  });

  final String authorName;
  final String authorInitial;
  final String rankTier;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final initial =
        authorInitial.trim().isNotEmpty
            ? authorInitial.trim().substring(0, 1)
            : (authorName.trim().isEmpty
                ? '同'
                : authorName.trim().substring(0, 1));
    return StudyPanel(
      tone: StudyPanelTone.quiet,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppPalette.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppPalette.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              authorName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          StudySoftTag(text: rankTier, accent: AppPalette.primaryAccent),
          if (isMine) ...[
            const SizedBox(width: 6),
            const StudySoftTag(text: '我发布的', accent: AppPalette.primary),
          ],
        ],
      ),
    );
  }
}

class _ReplayMp4Player extends StatefulWidget {
  const _ReplayMp4Player({required this.videoUrl});

  final String videoUrl;

  @override
  State<_ReplayMp4Player> createState() => _ReplayMp4PlayerState();
}

class _ReplayMp4PlayerState extends State<_ReplayMp4Player> {
  late final VideoPlayerController _controller;
  late final Future<void> _future;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(
      _resolveUrl(widget.videoUrl),
    );
    _future = _controller.initialize().then((_) async {
      await _controller.setLooping(false);
      if (mounted) setState(() {});
    });
    _controller.addListener(_onChanged);
  }

  Uri _resolveUrl(String raw) {
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Uri.parse(raw);
    }
    return Uri.parse('${ApiConfig.baseUrl}$raw');
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _togglePlay() async {
    if (!_controller.value.isInitialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final value = _controller.value;
        if (snapshot.hasError || value.hasError) {
          return StudyPanel(
            tone: StudyPanelTone.danger,
            child: Text(
              '视频暂时无法播放，请稍后再试。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: AppRadius.cardR,
              child: AspectRatio(
                aspectRatio:
                    value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(_controller),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _togglePlay,
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: AppPalette.textPrimary.withValues(
                              alpha: 0.48,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            value.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: AppPalette.primaryAccent,
                bufferedColor: AppPalette.outline,
                backgroundColor: AppPalette.warmTint,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReplayCommentsPanel extends StatelessWidget {
  const _ReplayCommentsPanel({
    required this.controller,
    required this.comments,
    required this.loading,
    required this.onSubmit,
    required this.onRefresh,
  });

  final TextEditingController controller;
  final List<ReplayComment> comments;
  final bool loading;
  final VoidCallback onSubmit;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '评论',
            subtitle: '说说这段讲解哪里讲得清楚。',
            action: IconButton(
              tooltip: '刷新评论',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLength: 200,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    hintText: '写一句鼓励或补充...',
                    filled: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: onSubmit, child: const Text('发送')),
            ],
          ),
          const SizedBox(height: 10),
          if (loading)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (comments.isEmpty)
            const StudyEmptyHint('还没有评论，来写第一句吧。')
          else
            ...comments.map(
              (comment) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ReplayCommentTile(comment: comment),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplayCommentTile extends StatelessWidget {
  const _ReplayCommentTile({required this.comment});

  final ReplayComment comment;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppPalette.warmTint.withValues(alpha: 0.45),
        borderRadius: AppRadius.buttonR,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            comment.isMine ? '${comment.studentName}（我）' : comment.studentName,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: AppPalette.primary),
          ),
          const SizedBox(height: 4),
          Text(comment.body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ReplayTransportBar extends StatelessWidget {
  const _ReplayTransportBar({
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.hasAudio,
    required this.onPlayPause,
    required this.onSeekStart,
    required this.onSeekEnd,
    required this.onSeekChanged,
  });

  final bool playing;
  final int positionMs;
  final int durationMs;
  final bool hasAudio;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onSeekChanged;

  @override
  Widget build(BuildContext context) {
    final maxMs = durationMs <= 0 ? 1.0 : durationMs.toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        boxShadow: AppShadows.paper,
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton.filled(
                onPressed: onPlayPause,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              Expanded(
                child: Slider(
                  value: positionMs.clamp(0, durationMs).toDouble(),
                  max: maxMs,
                  onChangeStart: (_) => onSeekStart(),
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmtTime(positionMs),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Text(
                hasAudio
                    ? '含录音 ${_fmtTime(durationMs)}'
                    : '过程回放 ${_fmtTime(durationMs)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              Text(
                _fmtTime(durationMs),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtTime(int ms) {
    final totalSec = (ms / 1000).floor();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
