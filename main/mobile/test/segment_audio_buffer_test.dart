import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_feynman/services/segment_audio_buffer.dart';

void main() {
  test('SegmentAudioBuffer stores and clears pcm chunks', () {
    final buffer = SegmentAudioBuffer();

    expect(buffer.isEmpty, isTrue);
    buffer.add(Uint8List.fromList([1, 2, 3]));
    expect(buffer.isNotEmpty, isTrue);
    expect(buffer.length, 1);

    buffer.add(Uint8List.fromList([4, 5]));
    expect(buffer.length, 2);
    expect(buffer.chunks.first, Uint8List.fromList([1, 2, 3]));

    buffer.clear();
    expect(buffer.isEmpty, isTrue);
  });
}
