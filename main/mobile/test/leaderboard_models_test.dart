import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leaderboard entry payload keeps scope fields', () {
    final entry = {
      'rank': 1,
      'studentName': '小太阳',
      'powerScore': 640,
      'rankTier': '黄金',
      'titleLabel': 'AI 费曼实验校 · 二次根式第 1 名',
    };
    expect(entry['rankTier'], '黄金');
    expect((entry['titleLabel'] as String).contains('第 1 名'), isTrue);
  });
}
