import 'dart:typed_data';

import 'package:ai_feynman/utils/pcm_wav.dart';
import 'package:ai_feynman/widgets/replay_ink_canvas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pcm16MonoToWav wraps PCM with RIFF header', () {
    final pcm = Uint8List.fromList(List<int>.filled(320, 0));
    final wav = pcm16MonoToWav(pcm);
    expect(wav.length, 44 + pcm.length);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });

  test('replayInkFrameAt uses latest snapshot not cumulative boxes', () {
    final timeline = [
      {
        'tMs': 100,
        'layoutWidth': 400,
        'layoutHeight': 300,
        'strokes': [
          {
            'stepId': 'step_1',
            'points': [
              [10.0, 10.0],
              [50.0, 40.0],
            ],
          },
        ],
      },
      {
        'tMs': 500,
        'layoutWidth': 400,
        'layoutHeight': 300,
        'strokes': [
          {
            'stepId': 'step_1',
            'points': [
              [100.0, 100.0],
              [120.0, 140.0],
            ],
          },
        ],
      },
    ];
    final at250 = replayInkFrameAt(timeline, 250);
    expect(at250?.tMs, 100);
    final at600 = replayInkFrameAt(timeline, 600);
    expect(at600?.tMs, 500);
    expect(at600?.strokes.first.points.first, const Offset(100, 100));
  });

  test('replayTimelineMaxMs considers audio and events', () {
    final ms = replayTimelineMaxMs(
      inkTimeline: [
        {'tMs': 800},
      ],
      turnsTimeline: [
        {'tMs': 1200},
      ],
      storedDurationMs: 200,
      audioDurationMs: 5000,
    );
    expect(ms, 5000);
  });
}
