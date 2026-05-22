import 'dart:async';

import 'package:flutter/material.dart';

import '../services/replay_service.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';

class ReplayPage extends StatefulWidget {
  const ReplayPage({super.key, required this.sessionId, this.studentId});

  final String sessionId;
  final int? studentId;

  @override
  State<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends State<ReplayPage> {
  final _service = ReplayService();
  Map<String, dynamic>? _payload;
  String? _error;
  bool _playing = false;
  int _positionMs = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _service.fetchReplay(widget.sessionId, studentId: widget.studentId);
      if (!mounted) return;
      setState(() => _payload = p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _toggle() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    final duration = (_payload?['durationMs'] as num?)?.toInt() ?? 0;
    setState(() {
      _playing = true;
      if (_positionMs >= duration) _positionMs = 0;
    });
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      setState(() {
        _positionMs += 120;
        if (duration > 0 && _positionMs >= duration) {
          _positionMs = duration;
          _playing = false;
          _timer?.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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
            ? Center(child: Text(_error ?? '加载中...'))
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.pageEdge),
                children: [
                  FormulaText(
                    p['questionPrompt'] as String? ?? '暂无题面',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 240,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppPalette.surface,
                        borderRadius: AppRadius.cardR,
                        boxShadow: AppShadows.paper,
                      ),
                      child: CustomPaint(
                        painter: _ReplayInkPainter(
                          timeline: (p['inkTimeline'] as List?) ?? const [],
                          positionMs: _positionMs,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _progress(p),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _toggle,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    label: Text(_playing ? '暂停' : '播放过程回放'),
                  ),
                  const SizedBox(height: 12),
                  ..._visibleTurns(p).map(
                    (t) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.surface,
                        borderRadius: AppRadius.buttonR,
                        boxShadow: AppShadows.paper,
                      ),
                      child: FormulaText(
                        '${t['displayName'] ?? t['role']}: ${t['text'] ?? ''}',
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  double _progress(Map<String, dynamic> p) {
    final duration = (p['durationMs'] as num?)?.toInt() ?? 0;
    if (duration <= 0) return 0;
    return (_positionMs / duration).clamp(0.0, 1.0);
  }

  List<Map<String, dynamic>> _visibleTurns(Map<String, dynamic> p) {
    final raw = p['turnsTimeline'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .where((t) => ((t['tMs'] as num?)?.toInt() ?? 0) <= _positionMs)
        .toList(growable: false);
  }
}

class _ReplayInkPainter extends CustomPainter {
  _ReplayInkPainter({required this.timeline, required this.positionMs});
  final List timeline;
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppPalette.secondary
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    var y = 36.0;
    for (final frame in timeline.whereType<Map<String, dynamic>>()) {
      final t = (frame['tMs'] as num?)?.toInt() ?? 0;
      if (t > positionMs) continue;
      final steps = frame['steps'];
      if (steps is! List) continue;
      for (final step in steps.whereType<Map<String, dynamic>>()) {
        final box = step['boundingBox'];
        if (box is Map) {
          final x = ((box['x'] as num?)?.toDouble() ?? 24).clamp(8.0, size.width - 80);
          final w = ((box['width'] as num?)?.toDouble() ?? 120).clamp(40.0, size.width - x - 8);
          final h = ((box['height'] as num?)?.toDouble() ?? 28).clamp(18.0, 64.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(8)),
            paint,
          );
          y += h + 18;
        }
      }
    }
    if (timeline.isEmpty) {
      final textPainter = TextPainter(
        text: const TextSpan(
          text: '暂无笔迹时间轴',
          style: TextStyle(color: AppPalette.textSecondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      textPainter.paint(canvas, const Offset(24, 24));
    }
  }

  @override
  bool shouldRepaint(covariant _ReplayInkPainter oldDelegate) {
    return oldDelegate.positionMs != positionMs || oldDelegate.timeline != timeline;
  }
}
