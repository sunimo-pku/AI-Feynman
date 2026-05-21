import 'package:ai_feynman/data/live_lecture_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveServerEvent.fromJson', () {
    test('listening event', () {
      final e = LiveServerEvent.fromJson({
        'type': 'listening',
        'sessionId': 'sess-1',
      });
      expect(e.type, LiveServerEventType.listening);
      expect(e.sessionId, 'sess-1');
      expect(e.payload, isA<LiveListeningPayload>());
    });

    test('asr_segment event preserves text', () {
      final e = LiveServerEvent.fromJson({
        'type': 'asr_segment',
        'sessionId': 'sess-1',
        'text': '我先把根号十二化成二根号三',
      });
      expect(e.type, LiveServerEventType.asrSegment);
      expect((e.payload as LiveAsrSegmentPayload).text, '我先把根号十二化成二根号三');
    });

    test('agent_turn_start carries role / highlight', () {
      final e = LiveServerEvent.fromJson({
        'type': 'agent_turn_start',
        'sessionId': 'sess-1',
        'turnId': 'turn_1',
        'role': 'xiaoming',
        'displayName': '小明',
        'highlightStepIds': ['step_1', 'step_2'],
      });
      final p = e.payload as LiveAgentTurnStartPayload;
      expect(p.turnId, 'turn_1');
      expect(p.role, 'xiaoming');
      expect(p.displayName, '小明');
      expect(p.highlightStepIds, ['step_1', 'step_2']);
    });

    test('agent_turn_delta carries delta string', () {
      final e = LiveServerEvent.fromJson({
        'type': 'agent_turn_delta',
        'sessionId': 'sess-1',
        'turnId': 'turn_1',
        'delta': '你刚才说',
      });
      final p = e.payload as LiveAgentTurnDeltaPayload;
      expect(p.delta, '你刚才说');
    });

    test('round_done with completed', () {
      final e = LiveServerEvent.fromJson({
        'type': 'round_done',
        'sessionId': 'sess-1',
        'status': 'completed',
        'masteryDelta': 1,
      });
      final p = e.payload as LiveRoundDonePayload;
      expect(p.status, 'completed');
      expect(p.masteryDelta, 1);
    });

    test('round_done with missing masteryDelta falls back to 0', () {
      final e = LiveServerEvent.fromJson({
        'type': 'round_done',
        'sessionId': 'sess-1',
        'status': 'needs_explanation',
      });
      final p = e.payload as LiveRoundDonePayload;
      expect(p.masteryDelta, 0);
    });

    test('unknown event does not throw', () {
      final e = LiveServerEvent.fromJson({
        'type': 'something_else',
        'sessionId': 'sess-1',
      });
      expect(e.type, LiveServerEventType.unknown);
      expect((e.payload as LiveUnknownPayload).rawType, 'something_else');
    });

    test('warning carries message', () {
      final e = LiveServerEvent.fromJson({
        'type': 'warning',
        'sessionId': 'sess-1',
        'message': 'asr_window_failed',
      });
      expect(e.type, LiveServerEventType.warning);
      expect((e.payload as LiveWarningPayload).message, 'asr_window_failed');
    });

    test('error fallback message when missing', () {
      final e = LiveServerEvent.fromJson({
        'type': 'error',
        'sessionId': 'sess-1',
      });
      expect((e.payload as LiveErrorPayload).message, 'error');
    });
  });

  group('LiveClientEvent', () {
    test('sessionStart payload has all fields', () {
      final p = LiveClientEvent.sessionStart(
        sessionId: 'sess-1',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q-s16-3-001',
        questionPrompt: r'\sqrt{12}-\sqrt{27}',
      );
      expect(p['type'], 'session_start');
      expect(p['sessionId'], 'sess-1');
      expect(p['sectionId'], 'pep-g8-down-s16-3');
      expect(p['questionId'], 'q-s16-3-001');
      expect(p['questionPrompt'], r'\sqrt{12}-\sqrt{27}');
    });

    test('audioChunk preserves seq and base64', () {
      final p = LiveClientEvent.audioChunk(
        sessionId: 'sess-1',
        seq: 12,
        base64Data: 'AAA=',
      );
      expect(p['type'], 'audio_chunk');
      expect(p['seq'], 12);
      expect(p['format'], 'pcm16');
      expect(p['sampleRate'], 16000);
      expect(p['base64'], 'AAA=');
    });

    test('pauseDetected carries silenceMs', () {
      final p = LiveClientEvent.pauseDetected(
        sessionId: 'sess-1',
        silenceMs: 1600,
      );
      expect(p['type'], 'pause_detected');
      expect(p['silenceMs'], 1600);
    });

    test('studentInterrupt carries reason', () {
      final p = LiveClientEvent.studentInterrupt(
        sessionId: 'sess-1',
        reason: 'pen',
      );
      expect(p['type'], 'student_interrupt');
      expect(p['reason'], 'pen');
    });
  });
}
