import 'dart:async';

import 'package:flutter/foundation.dart';

/// 调用后端 `/ocr/ink` 的辅助 service（整板 HWR）。
///
/// 第十二轮第五轮（砍 OCR）：讲题主链路已不再依赖 OCR —— 多模态 LLM
/// （Qwen-VL / Kimi-K2.6）直接读 `boardImageBase64`，并产出 `boardSummary`
/// 作为白板的精简文字摘要。
///
/// 这里把 [OcrService] 退化成 **noop**：
///   * 仍保留类型 + ValueNotifier，让 lecture_page 的 debug 面板等遗留 UI
///     不会因为引用缺失而炸；
///   * `recognizeBoard` / `recognize` 直接返回 `null` / 空结果，
///     不再发起 `/ocr/ink` 请求，省一笔网络 I/O 且避免老逻辑污染主流程。
///
/// 如果未来要重启异步 OCR（例如家长端慢速精校），可以直接恢复 git 历史里
/// 的旧实现 —— 后端 `/ocr/ink` 路由仍在线、签名未变。
@Deprecated('OCR 已退出讲题主链路，多模态 LLM 直接读 boardImageBase64')
class OcrService {
  OcrService();

  static final ValueNotifier<List<OcrStepGuess>> debugGuesses =
      ValueNotifier<List<OcrStepGuess>>(const <OcrStepGuess>[]);
  static final ValueNotifier<OcrBoardGuess?> debugBoard =
      ValueNotifier<OcrBoardGuess?>(null);

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
    return null;
  }

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
    return null;
  }

  void close() {}
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
