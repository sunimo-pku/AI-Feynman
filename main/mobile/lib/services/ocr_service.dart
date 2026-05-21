import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';

/// 调用后端 `/ocr/ink` 的辅助 service（第十轮）。
///
/// 把当前题目的 `referenceSteps` + 学生白板的 step 列表送给后端，拿到
/// 推断的 `latex / plainText`，回写到 ink_snapshot / lecture submit 的 step。
///
/// 失败语义：所有异常都被吞掉 → 返回 null，调用方按「OCR 失败、白板坐标
/// 仍能用」继续走（brief 第 9 节明确要求）。
class OcrService {
  OcrService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 6);

  final http.Client _client;
  final Duration _timeout;

  static final ValueNotifier<List<OcrStepGuess>> debugGuesses =
      ValueNotifier<List<OcrStepGuess>>(const <OcrStepGuess>[]);

  Future<List<OcrStepGuess>?> recognize({
    required String sectionId,
    required String questionId,
    required List<String> referenceSteps,
    required List<OcrStepInput> steps,
  }) async {
    if (steps.isEmpty) return const <OcrStepGuess>[];
    try {
      final resp = await _client
          .post(
            ApiConfig.uri('/ocr/ink'),
            headers: const {
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: utf8.encode(jsonEncode({
              'sectionId': sectionId,
              'questionId': questionId,
              'mode': 'hwr',
              'referenceSteps': referenceSteps,
              'steps': steps
                  .map((s) => {
                        'stepId': s.stepId,
                        'strokeCount': s.strokeCount,
                        if (s.boundingBox != null) 'boundingBox': s.boundingBox,
                        if (s.imageBase64.isNotEmpty)
                          'imageBase64': s.imageBase64,
                      })
                  .toList(growable: false),
            })),
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final raw = decoded['steps'];
      if (raw is! List) return null;
      final guesses = raw
          .whereType<Map<String, dynamic>>()
          .map(OcrStepGuess.fromJson)
          .toList(growable: false);
      debugGuesses.value = guesses;
      return guesses;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } catch (_) {
      return null;
    }
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
      source: json['source'] as String? ?? 'fallback',
      mode: json['mode'] as String? ?? 'rule',
    );
  }
}
