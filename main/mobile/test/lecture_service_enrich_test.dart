import 'package:flutter_test/flutter_test.dart';

import 'package:ai_feynman/data/lecture_models.dart';
import 'package:ai_feynman/services/lecture_service.dart';

/// 第十二轮第五轮（砍 OCR）：
/// `enrichWithOcr` 不再调 `/ocr/ink`，只负责把 boardImageBase64 拼到请求上。
/// 这组用例锁死它的新行为：
///   * 没有图片入参时，直接返回原始 request（pass-through）；
///   * 有图片入参时，复制 request 并把 boardImageBase64 写进去，
///     其它字段保持不变；
///   * 不发起任何网络请求 —— 即便没有传 client，调用也立即返回（不超时）。
void main() {
  late LectureService service;

  setUp(() {
    service = LectureService();
  });

  tearDown(() => service.close());

  LectureSubmitRequest _baseRequest() {
    return const LectureSubmitRequest(
      sectionId: 'pep-g8-down-s16-1',
      questionId: 'q1',
      questionPrompt: r'化简 $\sqrt{12}$',
      standardAnswer: r'2\sqrt{3}',
      studentSpeechText: '我先化简再合并',
      steps: <LectureStepPayload>[
        LectureStepPayload(
          stepId: 'board',
          strokeCount: 5,
          boundingBox: BoundingBoxPayload(
            x: 0,
            y: 0,
            width: 100,
            height: 50,
          ),
        ),
      ],
      roundIndex: 1,
      history: <LectureHistoryItem>[],
      roundBoardSnapshots: <RoundBoardSnapshot>[],
      boardImageBase64: '',
    );
  }

  test('enrichWithOcr returns the original request when no image is provided',
      () async {
    final original = _baseRequest();
    final result = await service.enrichWithOcr(
      original,
      referenceSteps: const <String>['先提取完全平方因数'],
      boardImageBase64: '',
    );
    expect(identical(result, original), isTrue,
        reason: '没有图片入参时应返回完全相同的引用，不做拷贝');
    expect(result.boardImageBase64, '');
  });

  test('enrichWithOcr copies the request and attaches boardImageBase64',
      () async {
    final original = _baseRequest();
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQIHWNg+A8AAAUAAUKpzGUAAAAASUVORK5CYII=';
    final enriched = await service.enrichWithOcr(
      original,
      referenceSteps: const <String>['先提取完全平方因数'],
      boardImageBase64: png,
    );
    expect(identical(enriched, original), isFalse,
        reason: '有图片入参时应返回新对象，避免 mutate 调用方');
    expect(enriched.boardImageBase64, png);
    expect(enriched.sectionId, original.sectionId);
    expect(enriched.questionId, original.questionId);
    expect(enriched.questionPrompt, original.questionPrompt);
    expect(enriched.studentSpeechText, original.studentSpeechText);
    expect(enriched.steps.length, original.steps.length);
    expect(enriched.roundIndex, original.roundIndex);
  });

  test('enrichWithOcr does not call the network and returns immediately',
      () async {
    final original = _baseRequest();
    final sw = Stopwatch()..start();
    final result = await service.enrichWithOcr(
      original,
      referenceSteps: const <String>['先提取完全平方因数'],
      boardImageBase64: 'aGVsbG8=',
    );
    sw.stop();
    expect(result.boardImageBase64, 'aGVsbG8=');
    expect(sw.elapsedMilliseconds, lessThan(200),
        reason: 'enrichWithOcr 必须是纯本地拼装，不应触发任何网络 I/O');
  });
}
