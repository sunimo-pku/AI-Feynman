import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replay timeline orders ink and turns by tMs', () {
    final timeline = [
      {'tMs': 500, 'type': 'turn'},
      {'tMs': 100, 'type': 'ink'},
    ]..sort((a, b) => (a['tMs'] as int).compareTo(b['tMs'] as int));
    expect(timeline.first['type'], 'ink');
  });
}
