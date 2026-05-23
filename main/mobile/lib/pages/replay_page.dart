import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../data/lecture_models.dart';
import '../services/replay_service.dart';
import '../theme/app_theme.dart';
import '../utils/pcm_wav.dart';
import '../widgets/agent_message_bubble.dart';
import '../widgets/formula_text.dart';
import '../widgets/replay_ink_canvas.dart';

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
  Uint8List? _wavBytes;
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
        _wavBytes = wav;
      });
      _bindPlayerEvents();
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

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _posSub?.cancel();
    _completeSub?.cancel();
    unawaited(_player.dispose());
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: const Text('精彩讲题回放')),
      body: SafeArea(
        child: p == null
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
                        const SizedBox(height: 12),
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
                          hasAudio: _wavBytes != null && _wavBytes!.isNotEmpty,
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
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._buildTurnBubbles(p),
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
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
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
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
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
                hasAudio ? '含录音 ${_fmtTime(durationMs)}' : '过程回放 ${_fmtTime(durationMs)}',
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
