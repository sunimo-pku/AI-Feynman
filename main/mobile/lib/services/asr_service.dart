import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'auth_service.dart';

/// 一次性 PCM16（16kHz mono）转写，供每日挑战等短语音场景。
class AsrService {
  AsrService({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _timeout = timeout ?? const Duration(seconds: 45);

  final http.Client _client;
  final Duration _timeout;

  Future<String> transcribePcm16(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) {
      throw AsrServiceException('没有录到语音，请靠近麦克风再试一次。');
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ...AuthService.instance.authHeaders(),
    };
    final resp = await _client
        .post(
          ApiConfig.uri('/asr'),
          headers: headers,
          body: jsonEncode({
            'audio': base64Encode(pcmBytes),
            'format': 'pcm',
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode == 401) {
      throw AsrServiceException('登录已过期，请重新登录。');
    }
    if (resp.statusCode != 200) {
      throw AsrServiceException('语音识别失败（${resp.statusCode}）');
    }
    final json = jsonDecode(resp.body);
    if (json is! Map<String, dynamic>) {
      throw AsrServiceException('语音识别返回格式异常');
    }
    final err = json['error'];
    if (err != null && err.toString().isNotEmpty) {
      throw AsrServiceException(err.toString());
    }
    final text = (json['text'] as String? ?? '').trim();
    if (text.isEmpty) {
      throw AsrServiceException('未识别到有效语音，请再讲一次。');
    }
    return text;
  }

  void close() => _client.close();
}

class AsrServiceException implements Exception {
  AsrServiceException(this.message);
  final String message;

  @override
  String toString() => message;
}
