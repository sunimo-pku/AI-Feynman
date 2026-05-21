import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/lecture_models.dart';

/// 调用 `POST /lecture/submit` 的客户端封装。
///
/// 设计要点：
///   * 不在业务层 try/catch 吞掉异常 —— 抛出 [LectureApiException]，
///     让 UI 拿到「能给学生看的中文原因」+「可重试」的语义。
///   * 路径统一经 [ApiConfig.uri]，禁止硬编码 IP / 协议。
///   * 仅依赖 `http` 包，避免引入新的网络层依赖。
class LectureService {
  LectureService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        // 第三轮起 `/lecture/submit` 内部走真实 Kimi K2.6（关思考模式），
        // 端到端中位数 5-15s、偶发 25s 拖尾；后端层自己有 28s timeout，
        // 失败会自动落 Mock fallback。前端 timeout 给 35s，**严格大于**
        // 后端 28s，确保「后端先 timeout 落 Mock」而不是「前端先报错
        // 但后端继续跑」。差出 7s 留给 JSON 校验 + 网络往返。
        _timeout = timeout ?? const Duration(seconds: 35);

  final http.Client _client;
  final Duration _timeout;

  Future<LectureSubmitResponse> submit(LectureSubmitRequest request) async {
    final uri = ApiConfig.uri('/lecture/submit');
    http.Response resp;
    try {
      resp = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode(request.toJson())),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const LectureApiException(
        userMessage: 'AI 同伴想得有点久（超过 35 秒），可能是网络不稳或 LLM 拥塞，'
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

  void close() => _client.close();

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
        return '当前章节还没有上线后端 Mock（仅 16.1 / 16.2 / 16.3 已就绪）。';
      case 422:
        return '提交字段不完整，请刷新页面重试。';
      case 429:
        return '提交太频繁了，喘口气再试。';
      case 500:
      case 502:
      case 503:
        return '后端暂时不可用，请稍后再试。';
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
