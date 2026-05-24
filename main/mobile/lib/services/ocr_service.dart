import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';

/// 调用后端 `/ocr/ink` 的辅助 service（整板 HWR）。
class OcrService {
  OcrService({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _timeout = timeout ?? const Duration(seconds: 22);

  final http.Client _client;
  final Duration _timeout;

  static final ValueNotifier<List<OcrStepGuess>> debugGuesses =
      ValueNotifier<List<OcrStepGuess>>(const <OcrStepGuess>[]);
  static final ValueNotifier<OcrBoardGuess?> debugBoard =
      ValueNotifier<OcrBoardGuess?>(null);

  /// 整板 PNG 一次 OCR；steps 仅传 strokeCount 等结构字段。
  Future<OcrBoardGuess?> recognizeBoard({
    required String sectionId,
    required String questionId,
    required List<String> referenceSteps,
    required String boardImageBase64,
    required int totalStrokeCount,
    String questionPrompt = '',
    String sectionLabel = '',
    List<String> knowledgeTags = const <String>[],
    List<OcrStepInput> steps = const <OcrStepInput>[],
  }) async {
    if (boardImageBase64.isEmpty) return null;
    try {
      final resp = await _client
          .post(
            ApiConfig.uri('/ocr/ink'),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(
              jsonEncode({
                'sectionId': sectionId,
                'questionId': questionId,
                'questionPrompt': questionPrompt,
                'sectionLabel': sectionLabel,
                'knowledgeTags': knowledgeTags,
                'mode': 'hwr',
                'boardImageBase64': boardImageBase64,
                'referenceSteps': referenceSteps,
                'steps':
                    steps.isEmpty
                        ? [
                          {'stepId': 'board', 'strokeCount': totalStrokeCount},
                        ]
                        : steps
                            .map(
                              (s) => {
                                'stepId': s.stepId,
                                'strokeCount': s.strokeCount,
                                if (s.boundingBox != null)
                                  'boundingBox': s.boundingBox,
                              },
                            )
                            .toList(growable: false),
              }),
            ),
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final rawBoard = decoded['board'];
      if (rawBoard is! Map<String, dynamic>) return null;
      final board = OcrBoardGuess.fromJson(rawBoard);
      debugBoard.value = board;
      final rawSteps = decoded['steps'];
      if (rawSteps is List) {
        debugGuesses.value = rawSteps
            .whereType<Map<String, dynamic>>()
            .map(OcrStepGuess.fromJson)
            .toList(growable: false);
      }
      return board;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 兼容旧调用：整板 OCR 的别名。
  Future<List<OcrStepGuess>?> recognize({
    required String sectionId,
    required String questionId,
    required List<String> referenceSteps,
    required List<OcrStepInput> steps,
    String questionPrompt = '',
    String sectionLabel = '',
    List<String> knowledgeTags = const <String>[],
    String boardImageBase64 = '',
  }) async {
    final totalStrokes = steps.fold<int>(0, (sum, s) => sum + s.strokeCount);
    final board = await recognizeBoard(
      sectionId: sectionId,
      questionId: questionId,
      referenceSteps: referenceSteps,
      boardImageBase64: boardImageBase64,
      totalStrokeCount: totalStrokes,
      questionPrompt: questionPrompt,
      sectionLabel: sectionLabel,
      knowledgeTags: knowledgeTags,
      steps: steps,
    );
    if (board == null) return null;
    if (board.latex.isEmpty && board.plainText.isEmpty) {
      return steps
          .map(
            (s) => OcrStepGuess(
              stepId: s.stepId,
              latex: '',
              plainText: '',
              confidence: 0,
              source: 'empty',
              mode: 'hwr',
            ),
          )
          .toList(growable: false);
    }
    return [
      OcrStepGuess(
        stepId: 'board',
        latex: board.latex,
        plainText: board.plainText,
        confidence: board.confidence,
        source: board.source,
        mode: board.mode,
      ),
    ];
  }

  void close() => _client.close();
}

class OcrStepInput {
  const OcrStepInput({
    required this.stepId,
    required this.strokeCount,
    this.boundingBox,
    this.imageBase64 = '',
  });

  final String stepId;
  final int strokeCount;
  final Map<String, dynamic>? boundingBox;
  final String imageBase64;
}

class OcrBoardGuess {
  const OcrBoardGuess({
    required this.latex,
    required this.plainText,
    required this.confidence,
    required this.source,
    required this.mode,
  });

  final String latex;
  final String plainText;
  final double confidence;
  final String source;
  final String mode;

  factory OcrBoardGuess.fromJson(Map<String, dynamic> json) {
    return OcrBoardGuess(
      latex: json['latex'] as String? ?? '',
      plainText: json['plainText'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      source: json['source'] as String? ?? 'empty',
      mode: json['mode'] as String? ?? 'hwr',
    );
  }
}

class OcrStepGuess {
  const OcrStepGuess({
    required this.stepId,
    required this.latex,
    required this.plainText,
    required this.confidence,
    required this.source,
    required this.mode,
  });

  final String stepId;
  final String latex;
  final String plainText;
  final double confidence;
  final String source;
  final String mode;

  factory OcrStepGuess.fromJson(Map<String, dynamic> json) {
    return OcrStepGuess(
      stepId: json['stepId'] as String? ?? '',
      latex: json['latex'] as String? ?? '',
      plainText: json['plainText'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      source: json['source'] as String? ?? 'empty',
      mode: json['mode'] as String? ?? 'rule',
    );
  }
}
