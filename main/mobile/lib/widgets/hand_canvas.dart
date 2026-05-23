import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// OCR 导出缩放：让 Qwen-VL 收到的 PNG 长边落在 [targetLongEdge, maxLongEdge]。
@visibleForTesting
double ocrExportUniformScale({
  required double contentWidth,
  required double contentHeight,
  double targetLongEdge = 1024,
  double maxLongEdge = 2048,
}) {
  final longEdge = math.max(
    math.max(contentWidth, 1.0),
    math.max(contentHeight, 1.0),
  );
  var scale = targetLongEdge / longEdge;
  if (longEdge * scale > maxLongEdge) {
    scale = maxLongEdge / longEdge;
  }
  return scale;
}

/// 导出位图里笔迹线宽乘数，保证缩放后仍 ≥ [minStrokePx] 像素。
@visibleForTesting
double ocrExportStrokeMultiplier({
  required double baseStrokeWidth,
  required double layoutScale,
  double minStrokePx = 6,
}) {
  final scaled = baseStrokeWidth * layoutScale;
  if (scaled >= minStrokePx) return 1.0;
  return minStrokePx / scaled;
}

/// 手写板工具：画笔 / 橡皮擦。
enum CanvasDrawMode { pen, eraser }

/// 单个 step 的笔迹信息，供后端 `boundingBox` 占位使用。
class HandCanvasStepInfo {
  const HandCanvasStepInfo({
    required this.stepId,
    required this.strokeCount,
    required this.bounds,
  });

  final String stepId;
  final int strokeCount;
  final Rect bounds;
}

/// 手写笔迹的最小数据单元：一条由多个采样点组成的折线，绑定一个 `stepId`。
class _Stroke {
  _Stroke({required this.stepId, required this.startedAt});

  final String stepId;
  final DateTime startedAt;
  final List<Offset> points = <Offset>[];

  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.dx;
    var minY = points.first.dy;
    var maxX = minX;
    var maxY = minY;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

/// 控制器，承载笔迹状态，让父页面可以：
///   * 监听 `stepIds` 变化（按钮可用性切换）。
///   * 调用 `undo / clear / collectStepIds`。
///   * 通过 `setHighlight` 高亮某些 `stepId` 对应的笔迹。
class HandCanvasController extends ChangeNotifier {
  HandCanvasController();

  final List<_Stroke> _strokes = <_Stroke>[];
  Set<String> _highlight = const <String>{};
  int _nextStepIndex = 1;
  int _version = 0;
  DateTime? _lastPointerAt;

  void _bump() {
    _version += 1;
    notifyListeners();
  }

  /// 离笔多久后下一笔视为新的「解题步骤」。
  static const _stepGap = Duration(seconds: 1);

  bool get isEmpty => _strokes.isEmpty;

  bool get canUndo => _strokes.isNotEmpty;
  DateTime? get lastStrokeAt => _lastPointerAt;

  /// 当前画布上出现过的所有 step ID（按出现顺序，去重）。
  List<String> collectStepIds() {
    final seen = <String>{};
    final ordered = <String>[];
    for (final s in _strokes) {
      if (seen.add(s.stepId)) ordered.add(s.stepId);
    }
    return ordered;
  }

  /// 每个 step 的笔迹并集包围盒 + 笔画数，按 step 顺序返回。
  List<HandCanvasStepInfo> collectStepInfos() {
    final boxes = <String, Rect>{};
    final counts = <String, int>{};
    for (final s in _strokes) {
      if (s.points.isEmpty) continue;
      counts.update(s.stepId, (v) => v + 1, ifAbsent: () => 1);
      final r = s.bounds;
      boxes.update(s.stepId, (prev) => prev.expandToInclude(r), ifAbsent: () => r);
    }
    return collectStepIds().map((id) {
      final r = boxes[id] ?? Rect.zero;
      return HandCanvasStepInfo(
        stepId: id,
        strokeCount: counts[id] ?? 0,
        bounds: r,
      );
    }).toList(growable: false);
  }

  /// 把指定 [stepId] 的笔迹裁成 PNG，供 `/ocr/ink mode=hwr` + Qwen-VL 识别。
  Future<Uint8List?> exportStepPng(
    String stepId, {
    String penStyle = 'default',
  }) async {
    final stepStrokes = _strokes
        .where((s) => s.stepId == stepId && s.points.isNotEmpty)
        .toList(growable: false);
    return _exportStrokesPng(
      strokes: stepStrokes,
      penStyle: penStyle,
      padding: 28,
      minDim: 80,
    );
  }

  /// 导出整板 PNG（所有笔迹一次裁切），供整板 Qwen-VL OCR。
  Future<Uint8List?> exportBoardPng({String penStyle = 'default'}) async {
    final allStrokes =
        _strokes.where((s) => s.points.isNotEmpty).toList(growable: false);
    return _exportStrokesPng(
      strokes: allStrokes,
      penStyle: penStyle,
      padding: 36,
      minDim: 160,
    );
  }

  /// 离屏渲染笔迹为 OCR 友好 PNG：白底黑字 + 统一缩放，避免大屏 3dp 笔迹过细。
  Future<Uint8List?> _exportStrokesPng({
    required List<_Stroke> strokes,
    required String penStyle,
    required double padding,
    required double minDim,
  }) async {
    if (strokes.isEmpty) return null;

    var bounds = strokes.first.bounds;
    for (final s in strokes.skip(1)) {
      bounds = bounds.expandToInclude(s.bounds);
    }
    if (bounds == Rect.zero ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite) {
      return null;
    }

    final contentW = math.max(bounds.width, 1.0);
    final contentH = math.max(bounds.height, 1.0);
    final baseStroke = _HandCanvasPainter.strokeWidthForPenStyle(penStyle);
    final scale = ocrExportUniformScale(
      contentWidth: contentW,
      contentHeight: contentH,
    );
    final strokeMul = ocrExportStrokeMultiplier(
      baseStrokeWidth: baseStroke,
      layoutScale: scale,
    );
    final width = math.max(minDim, (contentW + padding * 2) * scale).ceil();
    final height = math.max(minDim, (contentH + padding * 2) * scale).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.save();
    canvas.scale(scale);
    canvas.translate(padding / scale - bounds.left, padding / scale - bounds.top);
    _HandCanvasPainter.paintStepStrokes(
      canvas: canvas,
      strokes: strokes,
      penStyle: penStyle,
      inkColor: const Color(0xFF111111),
      strokeWidthMultiplier: strokeMul,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Set<String> get highlightStepIds => _highlight;

  void setHighlight(Iterable<String> stepIds) {
    final next = stepIds.toSet();
    if (next.length == _highlight.length &&
        next.containsAll(_highlight)) {
      return;
    }
    _highlight = next;
    _bump();
  }

  void clearHighlight() => setHighlight(const <String>{});

  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    if (_strokes.isEmpty) {
      _nextStepIndex = 1;
    }
    _bump();
  }

  void clear() {
    if (_strokes.isEmpty && _highlight.isEmpty) return;
    _strokes.clear();
    _highlight = const <String>{};
    _nextStepIndex = 1;
    _lastPointerAt = null;
    _bump();
  }

  /// 橡皮擦：移除与 [point] 距离在 [radius] 内的笔画。
  void eraseAt(Offset point, {double radius = 24}) {
    if (_strokes.isEmpty) return;
    final r2 = radius * radius;
    _strokes.removeWhere((stroke) {
      for (final p in stroke.points) {
        final dx = p.dx - point.dx;
        final dy = p.dy - point.dy;
        if (dx * dx + dy * dy <= r2) return true;
      }
      return stroke.bounds.inflate(radius).contains(point);
    });
    if (_strokes.isEmpty) {
      _nextStepIndex = 1;
      _lastPointerAt = null;
    }
    _bump();
  }

  // —— 以下方法仅供 HandCanvas 内部调用 ——

  void _beginStroke(Offset point, DateTime now) {
    final stepId = _resolveStepId(now);
    final stroke = _Stroke(stepId: stepId, startedAt: now)..points.add(point);
    _strokes.add(stroke);
    _lastPointerAt = now;
    _bump();
  }

  void _extendStroke(Offset point) {
    if (_strokes.isEmpty) return;
    _strokes.last.points.add(point);
    _lastPointerAt = DateTime.now();
    _bump();
  }

  String _resolveStepId(DateTime now) {
    if (_strokes.isEmpty || _lastPointerAt == null) {
      final id = 'step_$_nextStepIndex';
      _nextStepIndex += 1;
      return id;
    }
    final gap = now.difference(_lastPointerAt!);
    if (gap > _stepGap) {
      final id = 'step_$_nextStepIndex';
      _nextStepIndex += 1;
      return id;
    }
    return _strokes.last.stepId;
  }
}

/// 平板手写板。
///
/// * 默认笔色 `#3B82F6`，圆头，3.0dp。
/// * [stylusOnly] 时仅接受电容笔，手指用于双指平移。
/// * 用 `RepaintBoundary` 与左侧讨论区做重绘隔离，符合 `MOBILE_STYLE.md` §4.2。
class HandCanvas extends StatefulWidget {
  const HandCanvas({
    super.key,
    required this.controller,
    this.backgroundColor = AppPalette.canvas,
    this.penStyle = 'default',
    this.edgeToEdge = false,
    this.drawingEnabled = true,
    this.stylusOnly = false,
    this.drawMode = CanvasDrawMode.pen,
    this.twoFingerPanEnabled = false,
  });

  final HandCanvasController controller;
  final Color backgroundColor;
  final String penStyle;

  /// 讲题页全屏白板：去掉卡片圆角与粗边框，占满父级区域。
  final bool edgeToEdge;

  /// 为 false 时不接受书写 / 橡皮擦（仍可双指平移）。
  final bool drawingEnabled;

  /// 仅电容笔书写；手指不参与落笔（双指仍可平移）。
  final bool stylusOnly;

  final CanvasDrawMode drawMode;

  /// 双指拖动平移画布视口。
  final bool twoFingerPanEnabled;

  @override
  State<HandCanvas> createState() => _HandCanvasState();
}

class _HandCanvasState extends State<HandCanvas> {
  int? _drawPointer;
  final Map<int, Offset> _pointers = <int, Offset>{};
  Offset? _lastPanFocal;
  Offset _panOffset = Offset.zero;

  static const double _eraserRadius = 24;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          borderRadius:
              widget.edgeToEdge ? BorderRadius.zero : AppRadius.cardR,
          border:
              widget.edgeToEdge
                  ? null
                  : Border.all(color: AppPalette.outline),
        ),
        clipBehavior: widget.edgeToEdge ? Clip.hardEdge : Clip.antiAlias,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          behavior: HitTestBehavior.opaque,
          child: Transform.translate(
            offset: _panOffset,
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _HandCanvasPainter(
                    strokes: widget.controller._strokes,
                    highlight: widget.controller._highlight,
                    version: widget.controller._version,
                    penStyle: widget.penStyle,
                    eraserMode: widget.drawMode == CanvasDrawMode.eraser,
                    eraserAt: _drawPointer != null && widget.drawMode == CanvasDrawMode.eraser
                        ? _pointers[_drawPointer]
                        : null,
                  ),
                  size: Size.infinite,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Offset _toCanvasSpace(Offset local) => local - _panOffset;

  bool _isDrawingTool(PointerDownEvent event) {
    if (!widget.drawingEnabled) return false;
    if (widget.stylusOnly && !_isStylus(event)) return false;
    return true;
  }

  bool _isStylus(PointerEvent event) {
    if (event.kind == ui.PointerDeviceKind.stylus ||
        event.kind == ui.PointerDeviceKind.invertedStylus) {
      return true;
    }
    // 桌面调试时允许鼠标落笔，真机仍只认电容笔。
    return kDebugMode && event.kind == ui.PointerDeviceKind.mouse;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (widget.twoFingerPanEnabled && _pointers.length >= 2) {
      _cancelDraw();
      _lastPanFocal = _focalPoint();
      return;
    }

    if (!_isDrawingTool(event)) return;
    if (_pointers.length > 1) return;

    _drawPointer = event.pointer;
    final point = _toCanvasSpace(event.localPosition);

    if (widget.drawMode == CanvasDrawMode.eraser) {
      widget.controller.eraseAt(point, radius: _eraserRadius);
      return;
    }

    widget.controller._beginStroke(point, DateTime.now());
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (widget.twoFingerPanEnabled && _pointers.length >= 2) {
      final focal = _focalPoint();
      if (_lastPanFocal != null) {
        setState(() {
          _panOffset += focal - _lastPanFocal!;
        });
      }
      _lastPanFocal = focal;
      return;
    }

    if (_drawPointer != event.pointer) return;

    final point = _toCanvasSpace(event.localPosition);
    if (widget.drawMode == CanvasDrawMode.eraser) {
      widget.controller.eraseAt(point, radius: _eraserRadius);
      return;
    }

    widget.controller._extendStroke(point);
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _lastPanFocal = null;
    }
    if (_drawPointer == event.pointer) {
      _drawPointer = null;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _lastPanFocal = null;
    }
    if (_drawPointer == event.pointer) {
      _drawPointer = null;
    }
  }

  void _cancelDraw() {
    _drawPointer = null;
  }

  Offset _focalPoint() {
    if (_pointers.isEmpty) return Offset.zero;
    var x = 0.0;
    var y = 0.0;
    for (final p in _pointers.values) {
      x += p.dx;
      y += p.dy;
    }
    final n = _pointers.length;
    return Offset(x / n, y / n);
  }
}

class _HandCanvasPainter extends CustomPainter {
  _HandCanvasPainter({
    required this.strokes,
    required this.highlight,
    required this.version,
    required this.penStyle,
    required this.eraserMode,
    this.eraserAt,
  });

  final List<_Stroke> strokes;
  final Set<String> highlight;
  final int version;
  final String penStyle;
  final bool eraserMode;
  final Offset? eraserAt;

  static const double _baseStrokeWidth = 3.0;
  static const double _highlightStrokeWidth = 4.0;
  static const Color _defaultColor = AppPalette.secondary;
  static const Color _highlightColor = AppPalette.primaryAccent;
  static const Color _haloColor = AppPalette.highlight;

  @override
  void paint(Canvas canvas, Size size) {
    _drawGuides(canvas, size);

    if (highlight.isNotEmpty) {
      final byStep = <String, Rect>{};
      for (final s in strokes) {
        if (!highlight.contains(s.stepId) || s.points.isEmpty) continue;
        final r = s.bounds;
        byStep.update(
          s.stepId,
          (prev) => prev.expandToInclude(r),
          ifAbsent: () => r,
        );
      }
      final haloPaint = Paint()
        ..color = _haloColor.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      for (final rect in byStep.values) {
        if (rect == Rect.zero) continue;
        final padded = rect.inflate(10);
        canvas.drawRRect(
          RRect.fromRectAndRadius(padded, const Radius.circular(12)),
          haloPaint,
        );
      }
    }

    paintStepStrokes(
      canvas: canvas,
      strokes: strokes,
      penStyle: penStyle,
      highlight: highlight,
    );

    if (eraserMode && eraserAt != null) {
      final eraserPaint = Paint()
        ..color = AppPalette.outline.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(eraserAt!, 24, eraserPaint);
    }
  }

  /// 离屏导出与主画布共用同一套笔迹绘制逻辑。
  static void paintStepStrokes({
    required Canvas canvas,
    required List<_Stroke> strokes,
    required String penStyle,
    Set<String> highlight = const <String>{},
    Color? inkColor,
    double strokeWidthMultiplier = 1.0,
  }) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final highlighted = highlight.contains(stroke.stepId);
      final baseWidth =
          highlighted ? _highlightStrokeWidth : strokeWidthForPenStyle(penStyle);
      final paint = Paint()
        ..color =
            inkColor ??
            (highlighted ? _highlightColor : _colorForPenStyle(penStyle))
        ..strokeWidth = baseWidth * strokeWidthMultiplier
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..maskFilter = penStyle == 'gold' && !highlighted
            ? const MaskFilter.blur(BlurStyle.normal, 1.4)
            : null;

      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, paint.strokeWidth / 2, paint);
        continue;
      }
      final path = ui.Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        final p = stroke.points[i];
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  /// 浅淡的水平参考线，模仿练习本网格。
  void _drawGuides(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppPalette.outline.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    const lineGap = 40.0;
    final count = math.max(1, (size.height / lineGap).floor());
    for (var i = 1; i <= count; i++) {
      final y = i * lineGap;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HandCanvasPainter old) {
    return old.version != version ||
        old.highlight != highlight ||
        old.penStyle != penStyle ||
        old.eraserMode != eraserMode ||
        old.eraserAt != eraserAt;
  }

  static Color _colorForPenStyle(String style) {
    return switch (style) {
      'gold' => const Color(0xFFD97706),
      _ => _defaultColor,
    };
  }

  static double strokeWidthForPenStyle(String style) {
    return switch (style) {
      'gold' => 4.0,
      _ => _baseStrokeWidth,
    };
  }
}
