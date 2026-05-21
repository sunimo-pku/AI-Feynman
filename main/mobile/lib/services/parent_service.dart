import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/parent_models.dart';
import '../data/round12_models.dart';
import 'auth_service.dart';

/// 家长端 HTTP 客户端封装（第十轮）。
///
/// 调用语义与 `LectureService` 对齐：失败抛 [ParentApiException] 带「能给
/// 用户看的中文 message」+ 「可重试」语义；超时 / 网络问题与业务错误分离。
class ParentService {
  ParentService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _client;
  final Duration _timeout;

  Future<ParentDashboardPayload> fetchDashboard({int? studentId}) async {
    final body = await _get('/parent/dashboard', studentId: studentId);
    return ParentDashboardPayload.fromJson(body);
  }

  Future<ParentPosterPayload> fetchPoster({int? studentId}) async {
    final body = await _get('/parent/poster', studentId: studentId);
    return ParentPosterPayload.fromJson(body);
  }

  Future<List<ParentChild>> fetchChildren() async {
    final body = await _get('/parent/children');
    final raw = body['children'];
    return raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(ParentChild.fromJson)
            .toList(growable: false)
        : const <ParentChild>[];
  }

  Future<ParentChild> bindChild({
    required String username,
    required String nickname,
  }) async {
    final uri = ApiConfig.uri('/parent/children/bind');
    final resp = await _client
        .post(
          uri,
          headers: AuthService.instance.authHeaders(),
          body: utf8.encode(jsonEncode({
            'username': username,
            'nickname': nickname,
          })),
        )
        .timeout(_timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ParentApiException(
        userMessage: '绑定孩子失败（HTTP ${resp.statusCode}）。',
        statusCode: resp.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const ParentApiException(userMessage: '绑定孩子返回格式不符合契约。');
    }
    return ParentChild.fromJson({...decoded, 'active': false});
  }

  Future<void> updateProfile({
    required String displayName,
    required String grade,
  }) async {
    final uri = ApiConfig.uri('/learning/profile');
    final resp = await _client
        .patch(
          uri,
          headers: AuthService.instance.authHeaders(),
          body: utf8.encode(jsonEncode({
            'displayName': displayName,
            'grade': grade,
          })),
        )
        .timeout(_timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ParentApiException(
        userMessage: '保存资料失败（HTTP ${resp.statusCode}）。',
        statusCode: resp.statusCode,
      );
    }
  }

  Future<List<ParentReviewCard>> fetchReviews({String? sectionId, int? studentId, int limit = 20}) async {
    final params = <String, String>{'limit': '$limit'};
    if (sectionId != null && sectionId.isNotEmpty) {
      params['sectionId'] = sectionId;
    }
    if (studentId != null && studentId > 0) {
      params['studentId'] = '$studentId';
    }
    final uri = ApiConfig.uri('/parent/reviews').replace(queryParameters: params);
    final raw = await _getJson(uri);
    if (raw is! List) {
      throw const ParentApiException(
        userMessage: '后端返回格式不符合契约（/parent/reviews）。',
      );
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ParentReviewCard.fromJson)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _get(String path, {int? studentId}) async {
    final uri = studentId == null || studentId <= 0
        ? ApiConfig.uri(path)
        : ApiConfig.uri(path).replace(queryParameters: {'studentId': '$studentId'});
    final body = await _getJson(uri);
    if (body is! Map<String, dynamic>) {
      throw const ParentApiException(
        userMessage: '后端返回格式不符合契约。',
      );
    }
    return body;
  }

  Future<dynamic> _getJson(Uri uri) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const ParentApiException(
        userMessage: '需要先登录家长账号才能查看 dashboard。',
        statusCode: 401,
      );
    }
    http.Response resp;
    try {
      resp = await _client
          .get(uri, headers: AuthService.instance.authHeaders())
          .timeout(_timeout);
    } on TimeoutException {
      throw const ParentApiException(
        userMessage: '请求超时（12s），请稍后再试。',
      );
    } on SocketException catch (e) {
      throw ParentApiException(
        userMessage: '连不上后端（${ApiConfig.baseUrl}）。请确认后端已启动。',
        cause: e,
      );
    } on http.ClientException catch (e) {
      throw ParentApiException(
        userMessage: '网络异常：${e.message}',
        cause: e,
      );
    }
    if (resp.statusCode == 401) {
      throw const ParentApiException(
        userMessage: '登录态已失效，请重新登录。',
        statusCode: 401,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ParentApiException(
        userMessage: '请求失败（HTTP ${resp.statusCode}）。',
        statusCode: resp.statusCode,
      );
    }
    return jsonDecode(utf8.decode(resp.bodyBytes));
  }

  void close() => _client.close();
}

class ParentApiException implements Exception {
  const ParentApiException({
    required this.userMessage,
    this.statusCode,
    this.cause,
  });

  final String userMessage;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'ParentApiException(status=$statusCode, msg=$userMessage)';
}
