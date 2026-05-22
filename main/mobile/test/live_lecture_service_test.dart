import 'dart:async';
import 'dart:convert';

import 'package:ai_feynman/services/live_lecture_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'connectAndStart resends session_start when switching questions',
    () async {
      final channels = <_FakeWebSocketChannel>[];
      final service = LiveLectureService(
        audioPlayer: _NoopAudioPlayer(),
        webSocketConnector: (uri) {
          final channel = _FakeWebSocketChannel();
          channels.add(channel);
          return channel;
        },
      );

      final firstConnected = await service.connectAndStart(
        sessionId: 'sess-q1',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q-s16-3-001',
        questionPrompt: r'\sqrt{12}',
      );
      final secondConnected = await service.connectAndStart(
        sessionId: 'sess-q2',
        sectionId: 'pep-g8-down-s16-3',
        questionId: 'q-s16-3-002',
        questionPrompt: r'\sqrt{27}',
      );

      expect(firstConnected, isTrue);
      expect(secondConnected, isTrue);
      expect(channels, hasLength(1));
      expect(channels.single.sent, hasLength(2));

      final firstPayload =
          jsonDecode(channels.single.sent[0]) as Map<String, dynamic>;
      final secondPayload =
          jsonDecode(channels.single.sent[1]) as Map<String, dynamic>;
      expect(firstPayload['type'], 'session_start');
      expect(firstPayload['sessionId'], 'sess-q1');
      expect(firstPayload['questionId'], 'q-s16-3-001');
      expect(secondPayload['type'], 'session_start');
      expect(secondPayload['sessionId'], 'sess-q2');
      expect(secondPayload['questionId'], 'q-s16-3-002');
      expect(secondPayload['questionPrompt'], r'\sqrt{27}');

      await service.dispose();
    },
  );

  test('ignores server events from stale sessionId', () async {
    final channels = <_FakeWebSocketChannel>[];
    final service = LiveLectureService(
      audioPlayer: _NoopAudioPlayer(),
      webSocketConnector: (uri) {
        final channel = _FakeWebSocketChannel();
        channels.add(channel);
        return channel;
      },
    );
    final received = <String>[];
    final sub = service.events.listen((event) {
      received.add(event.sessionId);
    });

    await service.connectAndStart(
      sessionId: 'sess-current',
      sectionId: 'pep-g8-down-s16-3',
      questionId: 'q-s16-3-001',
      questionPrompt: r'\sqrt{12}',
    );
    channels.single.addIncoming({'type': 'listening', 'sessionId': 'sess-old'});
    channels.single.addIncoming({
      'type': 'listening',
      'sessionId': 'sess-current',
    });
    await Future<void>.delayed(Duration.zero);

    expect(received, ['sess-current']);

    await sub.cancel();
    await service.dispose();
  });
}

class _FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  _FakeWebSocketChannel() : _sink = _FakeWebSocketSink();

  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final _FakeWebSocketSink _sink;

  List<String> get sent => _sink.sent;

  void addIncoming(Map<String, dynamic> payload) {
    _incoming.add(jsonEncode(payload));
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _FakeWebSocketSink implements WebSocketSink {
  final List<String> sent = <String>[];
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic event) {
    sent.add(event as String);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

class _NoopAudioPlayer implements AudioPlayer {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
