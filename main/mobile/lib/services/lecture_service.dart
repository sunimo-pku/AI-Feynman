import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/lecture_models.dart';
import 'auth_service.dart';
import 'ocr_service.dart';

/// 调用 `POST /lecture/submit` 的客户端封装。
///
/// 设计要点：
///   * 不在业务层 try/catch 吞掉异常 —— 抛出 [LectureApiException]，
///     让 UI 拿到「能给学生看的中文原因」+「可重试」的语义。
///   * 路径统一经 [ApiConfig.uri]，禁止硬编码 IP / 协议。
///   * 仅依赖 `http` 包，避免引入新的网络层依赖。
class LectureService {
  LectureService({http.Client? client, Duration? timeout, OcrService? ocrService})
      : _client = client ?? http.Client(),
        _ocrService = ocrService ?? OcrService(),
        // `/lecture/submit` 走 DeepSeek-V4-Flash 非思考模式的完整 JSON 路径；
        // 实时讲题优先走 `/lecture/live` 流式路径。后端层自己有 6s timeout。
        // 前端 timeout 给 12s，严格大于后端，确保后端能先返回明确错误，
        // 而不是前端先断开但后端继续跑。
        _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _client;
  final Duration _timeout;
  final OcrService _ocrService;

  /// 第十轮：在提交前先调一次 /ocr/ink，把空 latex / plainText 的步骤补上。
  ///
  /// `referenceSteps` 来自当前题目（[LectureQuestion.referenceSteps]），
  /// 调用方按 `LecturePage._onSubmit` 传入。OCR 失败时返回原 request,
  /// 不影响主提交。
  Future<LectureSubmitRequest> enrichWithOcr(
    LectureSubmitRequest request, {
    required List<String> referenceSteps,
  }) async {
    final needs = request.steps.any(
      (s) => s.latex.trim().isEmpty && s.plainText.trim().isEmpty,
    );
    if (!needs) return request;
    final guesses = await _ocrService.recognize(
      sectionId: request.sectionId,
      questionId: request.questionId,
      referenceSteps: referenceSteps,
      steps: request.steps
          .map((s) => OcrStepInput(
                stepId: s.stepId,
                strokeCount: s.strokeCount,
                boundingBox: {
                  'x': s.boundingBox.x,
                  'y': s.boundingBox.y,
                  'width': s.boundingBox.width,
                  'height': s.boundingBox.height,
                },
                imageBase64: '',
              ))
          .toList(growable: false),
    );
    if (guesses == null || guesses.isEmpty) return request;
    final byStep = {for (final g in guesses) g.stepId: g};
    final enrichedSteps = request.steps
        .map((s) => LectureStepPayload(
              stepId: s.stepId,
              strokeCount: s.strokeCount,
              boundingBox: s.boundingBox,
              latex: s.latex.isNotEmpty
                  ? s.latex
                  : (byStep[s.stepId]?.latex ?? ''),
              plainText: s.plainText.isNotEmpty
                  ? s.plainText
                  : (byStep[s.stepId]?.plainText ?? ''),
            ))
        .toList(growable: false);
    return LectureSubmitRequest(
      sectionId: request.sectionId,
      questionId: request.questionId,
      questionPrompt: request.questionPrompt,
      studentSpeechText: request.studentSpeechText,
      steps: enrichedSteps,
      roundIndex: request.roundIndex,
      history: request.history,
    );
  }

  Future<LectureSubmitResponse> submit(LectureSubmitRequest request) async {
    final uri = ApiConfig.uri('/lecture/submit');
    http.Response resp;
    try {
      // 第十轮：登录后自动带 Bearer，让后端把本次提交写入学生进度。
      // 未登录时仍走匿名 demo 路径，不会破坏第二轮以来的契约。
      final headers = AuthService.instance.authHeaders();
      resp = await _client
          .post(
            uri,
            headers: headers,
            body: utf8.encode(jsonEncode(request.toJson())),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const LectureApiException(
        userMessage: 'AI 同伴想得有点久（超过 12 秒），可能是网络不稳或 LLM 拥塞，'
            '稍等几秒再点一次「重新提交」试试。',
      );
    } on SocketException catch (e) {
      throw LectureApiException(
        userMessage: '连不上后端（${ApiConfig.baseUrl}）。请确认后端已启动，或检查局域网地址。',
        cause: e,
      );
    } on http.ClientException catch (e) {
      throw LectureApiException(
        userMessage: '网络请求失败：${e.message}',
        cause: e,
      );
    }

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const LectureApiException(
          userMessage: '后端返回的格式不符合契约，请联系开发同学检查 /lecture/submit。',
        );
      }
      return LectureSubmitResponse.fromJson(decoded);
    }

    final detail = _extractDetail(resp.bodyBytes);
    throw LectureApiException(
      statusCode: resp.statusCode,
      userMessage: _userMessageFor(resp.statusCode, detail),
      detail: detail,
    );
  }

  void close() {
    _client.close();
    _ocrService.close();
  }

  static String _extractDetail(List<int> bodyBytes) {
    try {
      final raw = utf8.decode(bodyBytes);
      if (raw.isEmpty) return '';
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['detail'] != null) {
        final detail = decoded['detail'];
        if (detail is String) return detail;
        return detail.toString();
      }
      return raw;
    } catch (_) {
      return '';
    }
  }

  static String _userMessageFor(int status, String detail) {
    switch (status) {
      case 400:
        return detail.isNotEmpty
            ? detail
            : '画板还没有内容，先写一两行思路再提交。';
      case 404:
        return '当前章节暂时无法提交讲题，请换一个小节再试。';
      case 422:
        return '提交字段不完整，请刷新页面重试。';
      case 429:
        return '提交太频繁了，喘口气再试。';
      case 500:
      case 502:
      case 503:
        return detail.isNotEmpty ? '讲题服务失败：$detail' : '讲题服务失败，请稍后再试。';
    }
    if (status >= 500) {
      return '后端暂时不可用（HTTP $status），请稍后再试。';
    }
    return '请求失败（HTTP $status），请稍后再试。';
  }
}

class LectureApiException implements Exception {
  const LectureApiException({
    required this.userMessage,
    this.statusCode,
    this.detail,
    this.cause,
  });

  final String userMessage;
  final int? statusCode;
  final String? detail;
  final Object? cause;

  @override
  String toString() => 'LectureApiException(status=$statusCode, '
      'userMessage=$userMessage, detail=$detail)';
}
