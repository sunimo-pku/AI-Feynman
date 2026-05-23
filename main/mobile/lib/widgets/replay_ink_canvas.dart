import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 回放时间轴上某一帧的笔迹快照。
class ReplayInkFrame {
  const ReplayInkFrame({
    required this.tMs,
    required this.layoutWidth,
    required this.layoutHeight,
    required this.strokes,
  });

  final int tMs;
  final double layoutWidth;
  final double layoutHeight;
  final List<ReplayStroke> strokes;

  factory ReplayInkFrame.fromJson(Map<String, dynamic> json) {
    final rawStrokes = json['strokes'];
    final strokes =
        rawStrokes is List
            ? rawStrokes
                .whereType<Map<String, dynamic>>()
                .map(ReplayStroke.fromJson)
                .where((s) => s.points.isNotEmpty)
                .toList(growable: false)
            : const <ReplayStroke>[];
    return ReplayInkFrame(
      tMs: (json['tMs'] as num?)?.toInt() ?? 0,
      layoutWidth: (json['layoutWidth'] as num?)?.toDouble() ?? 0,
      layoutHeight: (json['layoutHeight'] as num?)?.toDouble() ?? 0,
      strokes: strokes,
    );
  }
}

class ReplayStroke {
  const ReplayStroke({required this.stepId, required this.points});

  final String stepId;
  final List<Offset> points;

  factory ReplayStroke.fromJson(Map<String, dynamic> json) {
    final pts = <Offset>[];
    final raw = json['points'];
    if (raw is List) {
      for (final item in raw) {
        if (item is List && item.length >= 2) {
          pts.add(
            Offset(
              (item[0] as num).toDouble(),
              (item[1] as num).toDouble(),
            ),
          );
        }
      }
    }
    return ReplayStroke(
      stepId: json['stepId'] as String? ?? '',
      points: pts,
    );
  }
}

ReplayInkFrame? replayInkFrameAt(List<dynamic> timeline, int positionMs) {
  ReplayInkFrame? latest;
  for (final item in timeline) {
    if (item is! Map<String, dynamic>) continue;
    final frame = ReplayInkFrame.fromJson(item);
    if (frame.tMs > positionMs) break;
    if (frame.strokes.isNotEmpty) latest = frame;
  }
  return latest;
}

int replayTimelineMaxMs({
  required List<dynamic> inkTimeline,
  required List<dynamic> turnsTimeline,
  required int storedDurationMs,
  required int audioDurationMs,
}) {
  var maxMs = storedDurationMs;
  for (final item in inkTimeline) {
    if (item is Map) {
      final t = (item['tMs'] as num?)?.toInt() ?? 0;
      if (t > maxMs) maxMs = t;
    }
  }
  for (final item in turnsTimeline) {
    if (item is Map) {
      final t = (item['tMs'] as num?)?.toInt() ?? 0;
      if (t > maxMs) maxMs = t;
    }
  }
  if (audioDurationMs > maxMs) maxMs = audioDurationMs;
  return maxMs < 1000 ? 1000 : maxMs;
}

List<Map<String, dynamic>> replayTurnsVisibleAt(
  List<dynamic> turnsTimeline,
  int positionMs,
) {
  return turnsTimeline
      .whereType<Map<String, dynamic>>()
      .where((t) => ((t['tMs'] as num?)?.toInt() ?? 0) <= positionMs)
      .toList(growable: false);
}

Uint8List decodeReplayPcmChunks(List<dynamic> rawChunks) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in rawChunks) {
    if (chunk is! String || chunk.isEmpty) continue;
    try {
      builder.add(base64Decode(chunk));
    } catch (_) {}
  }
  return builder.toBytes();
}

/// 回放白板：按录制布局等比缩放笔迹。
class ReplayInkCanvas extends StatelessWidget {
  const ReplayInkCanvas({super.key, required this.frame});

  final ReplayInkFrame? frame;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.canvas,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outline.withValues(alpha: 0.6)),
      ),
      child: ClipRRect(
        borderRadius: AppRadius.cardR,
        child: CustomPaint(
          painter: _ReplayInkPainter(frame: frame),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ReplayInkPainter extends CustomPainter {
  _ReplayInkPainter({required this.frame});

  final ReplayInkFrame? frame;

  static const _inkColor = Color(0xFF1F2937);
  static const _strokeWidth = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppPalette.canvas);

    final f = frame;
    if (f == null || f.strokes.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: '该时刻暂无笔迹',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 32);
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, size.height / 2 - 10),
      );
      return;
    }

    final srcW = f.layoutWidth > 0 ? f.layoutWidth : size.width;
    final srcH = f.layoutHeight > 0 ? f.layoutHeight : size.height;
    final scaleX = size.width / srcW;
    final scaleY = size.height / srcH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final dx = (size.width - srcW * scale) / 2;
    final dy = (size.height - srcH * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final paint = Paint()
      ..color = _inkColor
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;

    for (final stroke in f.strokes) {
      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, _strokeWidth / 2, paint);
        continue;
      }
      final path = ui.Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReplayInkPainter oldDelegate) {
    return oldDelegate.frame != frame;
  }
}
