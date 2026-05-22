import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/round12_models.dart';
import 'auth_service.dart';

class Round12Service {
  Round12Service({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _client;
  final Duration _timeout;

  Future<PowerProfile> fetchPowerProfile() async {
    final json = await _getMap(ApiConfig.uri('/gamification/me'));
    return PowerProfile.fromJson(json);
  }

  Future<List<LeaderboardEntry>> fetchLeaderboard({
    required String scope,
    String sectionId = 'pep-g8-down-s16-3',
  }) async {
    final uri = ApiConfig.uri('/leaderboard').replace(queryParameters: {
      'scope': scope,
      'sectionId': sectionId,
    });
    final json = await _getMap(uri);
    final raw = json['entries'];
    return raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(LeaderboardEntry.fromJson)
            .toList(growable: false)
        : const <LeaderboardEntry>[];
  }

  Future<BountyToday> fetchBountyToday() async {
    final json = await _getMap(ApiConfig.uri('/bounty/today'));
    return BountyToday.fromJson(json);
  }

  Future<List<BountyChallenge>> fetchBounties() async {
    return (await fetchBountyToday()).challenges;
  }

  Future<BountySubmitResult> submitBounty({
    required String challengeId,
    required Map<String, num> circledBox,
    required String transcriptText,
  }) async {
    final json = await _postMap(ApiConfig.uri('/bounty/submit'), {
      'challengeId': challengeId,
      'circledBox': circledBox,
      'transcriptText': transcriptText,
    });
    return BountySubmitResult.fromJson(json);
  }

  Future<ShopCatalog> fetchShopCatalog() async {
    final json = await _getMap(ApiConfig.uri('/shop/catalog'));
    return ShopCatalog.fromJson(json);
  }

  Future<Map<String, dynamic>> redeem(
    String skuId, {
    Map<String, dynamic> address = const <String, dynamic>{},
  }) {
    return _postMap(ApiConfig.uri('/shop/redeem'), {
      'skuId': skuId,
      'address': address,
    });
  }

  Future<Map<String, dynamic>> fetchLedger() {
    return _getMap(ApiConfig.uri('/shop/ledger'));
  }

  Future<Map<String, dynamic>> fetchOrders() {
    return _getMap(ApiConfig.uri('/shop/orders'));
  }

  Future<Map<String, dynamic>> fetchProfile() {
    return _getMap(ApiConfig.uri('/learning/profile'));
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> patch) {
    return _patchMap(ApiConfig.uri('/learning/profile'), patch);
  }

  Future<Map<String, dynamic>> uploadQuestionImage(File file) async {
    await AuthService.instance.load();
    final request = http.MultipartRequest(
      'POST',
      ApiConfig.uri('/questions/upload-image'),
    );
    final token = AuthService.instance.currentToken;
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await request.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Round12ApiException('上传失败（HTTP ${resp.statusCode}）。');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const Round12ApiException('后端返回格式不符合契约。');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _getMap(Uri uri) async {
    await AuthService.instance.load();
    try {
      final resp = await _client
          .get(uri, headers: AuthService.instance.authHeaders())
          .timeout(_timeout);
      return _decodeMap(resp);
    } on TimeoutException {
      throw const Round12ApiException('请求超时，请稍后再试。');
    } on SocketException {
      throw const Round12ApiException('连不上后端（${ApiConfig.baseUrl}）。');
    }
  }

  Future<Map<String, dynamic>> _postMap(Uri uri, Map<String, dynamic> body) async {
    await AuthService.instance.load();
    final resp = await _client
        .post(
          uri,
          headers: AuthService.instance.authHeaders(),
          body: utf8.encode(jsonEncode(body)),
        )
        .timeout(_timeout);
    return _decodeMap(resp);
  }

  Future<Map<String, dynamic>> _patchMap(Uri uri, Map<String, dynamic> body) async {
    await AuthService.instance.load();
    final resp = await _client
        .patch(
          uri,
          headers: AuthService.instance.authHeaders(),
          body: utf8.encode(jsonEncode(body)),
        )
        .timeout(_timeout);
    return _decodeMap(resp);
  }

  Map<String, dynamic> _decodeMap(http.Response resp) {
    if (resp.statusCode == 401) {
      throw const Round12ApiException('请先登录后再使用这个功能。');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Round12ApiException('请求失败（HTTP ${resp.statusCode}）。');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const Round12ApiException('后端返回格式不符合契约。');
    }
    return decoded;
  }

  void close() => _client.close();
}

class Round12ApiException implements Exception {
  const Round12ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
