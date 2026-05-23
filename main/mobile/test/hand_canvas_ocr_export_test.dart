import 'package:ai_feynman/widgets/hand_canvas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ocrExportUniformScale', () {
    test('upscales small handwriting to target long edge', () {
      final scale = ocrExportUniformScale(
        contentWidth: 120,
        contentHeight: 80,
      );
      expect(scale, closeTo(1024 / 120, 0.01));
    });

    test('caps extremely large boards', () {
      final scale = ocrExportUniformScale(
        contentWidth: 3000,
        contentHeight: 800,
      );
      expect(3000 * scale, lessThanOrEqualTo(2048 + 0.01));
    });
  });

  group('ocrExportStrokeMultiplier', () {
    test('boosts stroke when layout scale leaves ink too thin', () {
      const layoutScale = 2048 / 1800;
      final mul = ocrExportStrokeMultiplier(
        baseStrokeWidth: 3,
        layoutScale: layoutScale,
      );
      expect(3 * layoutScale * mul, greaterThanOrEqualTo(6));
    });

    test('does not boost when strokes already thick enough', () {
      final mul = ocrExportStrokeMultiplier(
        baseStrokeWidth: 3,
        layoutScale: 5,
      );
      expect(mul, 1.0);
    });
  });
}
