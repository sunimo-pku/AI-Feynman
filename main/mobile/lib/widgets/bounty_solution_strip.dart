import 'package:flutter/material.dart';

import '../data/round12_models.dart';
import '../theme/app_theme.dart';
import 'formula_text.dart';

/// 每日挑战：展示「同学的错误解法」并在其上拖拽红框圈出错步。
class BountySolutionStrip extends StatefulWidget {
  const BountySolutionStrip({
    super.key,
    required this.challenge,
    this.initialBox,
    required this.onBoxChanged,
  });

  final BountyChallenge challenge;
  final Map<String, num>? initialBox;
  final ValueChanged<Map<String, num>> onBoxChanged;

  @override
  State<BountySolutionStrip> createState() => _BountySolutionStripState();
}

class _BountySolutionStripState extends State<BountySolutionStrip> {
  Offset? _start;
  Rect? _box;

  @override
  void initState() {
    super.initState();
    _box = _rectFromMap(widget.initialBox);
  }

  @override
  void didUpdateWidget(covariant BountySolutionStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.challenge.challengeId != widget.challenge.challengeId) {
      _box = _rectFromMap(widget.initialBox);
      _start = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.challenge.wrongSolution;
    return Material(
      color: AppPalette.surface.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.error.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: AppPalette.error.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '用手指拖红框，圈住上面出错的那一行',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppPalette.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) {
                    _start = _clamp(d.localPosition, size);
                    _updateBox(_start!, _start!, size);
                  },
                  onPanUpdate: (d) {
                    final start = _start;
                    if (start == null) return;
                    _updateBox(start, _clamp(d.localPosition, size), size);
                  },
                  child: CustomPaint(
                    foregroundPainter: _BountyBoxPainter(
                      box: _box,
                      canvasSize: Size(
                        widget.challenge.canvasWidth.toDouble(),
                        widget.challenge.canvasHeight.toDouble(),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < lines.length; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 22,
                                    height: 22,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: AppPalette.primary.withValues(
                                        alpha: 0.08,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: AppPalette.primary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FormulaText(
                                      lines[i],
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyLarge?.copyWith(height: 1.45),
                                      formulaStyle: Theme.of(
                                        context,
                                      ).textTheme.bodyLarge?.copyWith(
                                        color: AppPalette.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _clamp(Offset value, Size size) {
    return Offset(
      value.dx.clamp(0, size.width).toDouble(),
      value.dy.clamp(0, size.height).toDouble(),
    );
  }

  void _updateBox(Offset a, Offset b, Size localSize) {
    final local = Rect.fromPoints(a, b);
    final scaleX = widget.challenge.canvasWidth / localSize.width;
    final scaleY = widget.challenge.canvasHeight / localSize.height;
    final canvas = Rect.fromLTWH(
      local.left * scaleX,
      local.top * scaleY,
      local.width * scaleX,
      local.height * scaleY,
    );
    setState(() => _box = canvas);
    widget.onBoxChanged({
      'x': canvas.left.round(),
      'y': canvas.top.round(),
      'width': canvas.width.round(),
      'height': canvas.height.round(),
    });
  }

  Rect? _rectFromMap(Map<String, num>? raw) {
    if (raw == null) return null;
    return Rect.fromLTWH(
      (raw['x'] ?? 0).toDouble(),
      (raw['y'] ?? 0).toDouble(),
      (raw['width'] ?? 0).toDouble(),
      (raw['height'] ?? 0).toDouble(),
    );
  }
}

class _BountyBoxPainter extends CustomPainter {
  const _BountyBoxPainter({required this.box, required this.canvasSize});

  final Rect? box;
  final Size canvasSize;

  @override
  void paint(Canvas canvas, Size size) {
    final raw = box;
    if (raw == null || raw.width <= 0 || raw.height <= 0) return;
    final scaled = Rect.fromLTWH(
      raw.left / canvasSize.width * size.width,
      raw.top / canvasSize.height * size.height,
      raw.width / canvasSize.width * size.width,
      raw.height / canvasSize.height * size.height,
    );
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = AppPalette.error.withValues(alpha: 0.12);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = AppPalette.error;
    final rrect = RRect.fromRectAndRadius(scaled, const Radius.circular(10));
    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, stroke);
  }

  @override
  bool shouldRepaint(covariant _BountyBoxPainter oldDelegate) {
    return oldDelegate.box != box;
  }
}
