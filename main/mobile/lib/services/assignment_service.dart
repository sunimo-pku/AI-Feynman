import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/assignment_models.dart';
import 'auth_service.dart';

class AssignmentService {
  AssignmentService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 20);

  final http.Client _client;
  final Duration _timeout;

  Future<Map<String, dynamic>> _decode(http.Response resp) async {
    if (resp.statusCode == 401) {
      throw AssignmentApiException(
        userMessage: '登录态已失效，请重新登录。',
        statusCode: 401,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      String detail = 'HTTP ${resp.statusCode}';
      try {
        final body = jsonDecode(utf8.decode(resp.bodyBytes));
        if (body is Map && body['detail'] != null) {
          detail = body['detail'].toString();
        }
      } catch (_) {}
      throw AssignmentApiException(userMessage: detail, statusCode: resp.statusCode);
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const AssignmentApiException(userMessage: '后端返回格式不符合契约。');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const AssignmentApiException(
        userMessage: '需要先登录。',
        statusCode: 401,
      );
    }
    var uri = ApiConfig.uri(path);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    http.Response resp;
    try {
      final headers = AuthService.instance.authHeaders();
      switch (method) {
        case 'GET':
          resp = await _client.get(uri, headers: headers).timeout(_timeout);
        case 'POST':
          resp = await _client
              .post(uri, headers: headers, body: utf8.encode(jsonEncode(body ?? {})))
              .timeout(_timeout);
        case 'DELETE':
          resp = await _client.delete(uri, headers: headers).timeout(_timeout);
        default:
          throw StateError('Unsupported method $method');
      }
    } on TimeoutException {
      throw const AssignmentApiException(userMessage: '请求超时，请稍后再试。');
    } on SocketException catch (e) {
      throw AssignmentApiException(
        userMessage: '连不上后端（${ApiConfig.baseUrl}）。',
        cause: e,
      );
    }
    return _decode(resp);
  }

  Future<({List<AssignmentItem> assignments, int pendingCount, int completedCount})>
      fetchParentAssignments() async {
    final body = await _request(method: 'GET', path: '/parent/assignments');
    final raw = body['assignments'];
    final list = raw is List
        ? raw.whereType<Map<String, dynamic>>().map(AssignmentItem.fromJson).toList(growable: false)
        : const <AssignmentItem>[];
    return (
      assignments: list,
      pendingCount: (body['pendingCount'] as num?)?.toInt() ?? 0,
      completedCount: (body['completedCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<AssignmentRecommendation>> fetchRecommendations({int limit = 6}) async {
    final body = await _request(
      method: 'GET',
      path: '/parent/assignments/recommendations',
      query: {'limit': '$limit'},
    );
    final raw = body['recommendations'];
    if (raw is! List) return const <AssignmentRecommendation>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(AssignmentRecommendation.fromJson)
        .toList(growable: false);
  }

  Future<AssignmentItem> createAssignment({
    required String sourceType,
    required String sectionId,
    required DateTime dueAt,
    int difficulty = 1,
    String questionId = '',
    String questionPrompt = '',
    String title = '',
    String note = '',
    List<String> knowledgeTags = const [],
  }) async {
    final body = await _request(
      method: 'POST',
      path: '/parent/assignments',
      body: {
        'sourceType': sourceType,
        'sectionId': sectionId,
        'difficulty': difficulty,
        if (questionId.isNotEmpty) 'questionId': questionId,
        if (questionPrompt.isNotEmpty) 'questionPrompt': questionPrompt,
        if (title.isNotEmpty) 'title': title,
        if (note.isNotEmpty) 'note': note,
        'dueAt': dueAt.toUtc().toIso8601String(),
        if (knowledgeTags.isNotEmpty) 'knowledgeTags': knowledgeTags,
      },
    );
    return AssignmentItem.fromJson(body);
  }

  Future<AssignmentReport> fetchReport(String assignmentId) async {
    final body = await _request(
      method: 'GET',
      path: '/parent/assignments/$assignmentId/report',
    );
    return AssignmentReport.fromJson(body);
  }

  Future<void> deleteAssignment(String assignmentId) async {
    await _request(method: 'DELETE', path: '/parent/assignments/$assignmentId');
  }

  Future<RecognizedQuestion> recognizeImage(File file) async {
    if (!AuthService.instance.isLoggedIn) {
      throw const AssignmentApiException(userMessage: '需要先登录家长账号。', statusCode: 401);
    }
    final uri = ApiConfig.uri('/parent/assignments/recognize-image');
    final req = http.MultipartRequest('POST', uri);
    req.headers.addAll(AuthService.instance.authHeaders());
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await req.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    final body = await _decode(resp);
    return RecognizedQuestion.fromJson(body);
  }

  Future<({List<AssignmentItem> active, List<AssignmentItem> completed, int pendingCount})>
      fetchStudentAssignments() async {
    final body = await _request(method: 'GET', path: '/learning/assignments');
    List<AssignmentItem> readList(String key) {
      final raw = body[key];
      if (raw is! List) return const <AssignmentItem>[];
      return raw.whereType<Map<String, dynamic>>().map(AssignmentItem.fromJson).toList(growable: false);
    }

    return (
      active: readList('active'),
      completed: readList('completed'),
      pendingCount: (body['pendingCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<AssignmentItem> openAssignment(String assignmentId) async {
    final body = await _request(
      method: 'POST',
      path: '/learning/assignments/$assignmentId/open',
    );
    return AssignmentItem.fromJson(body);
  }

  void close() => _client.close();
}

class AssignmentApiException implements Exception {
  const AssignmentApiException({
    required this.userMessage,
    this.statusCode,
    this.cause,
  });

  final String userMessage;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => 'AssignmentApiException(status=$statusCode, msg=$userMessage)';
}
