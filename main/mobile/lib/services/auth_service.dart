import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import 'progress_repository.dart';
import 'review_repository.dart';

/// 第十轮：登录/注册 + token 持久化。
///
/// 设计取舍：
///   * 单例 [instance] + `ChangeNotifier`：登录状态会被多页订阅（讲题页、
///     家长端、首页 AppBar），用 provider/riverpod 太重，单例足够。
///   * token 落 `shared_preferences`，与 progress / review 仓库同口径。
///   * 任何阶段失败都**不**抛 `Exception`：登录注册按钮上回显 [AuthFailure]
///     的中文 message，避免把 SocketException 直接抛到 build 阶段。
///   * 「未登录」是一等公民：[currentToken] 为空字符串时仍允许进入学生端
///     讲题闭环，与第九轮 demo 链路完全兼容；只有家长端 / 同步接口需要登录。
class AuthService extends ChangeNotifier {
  AuthService._({http.Client? client}) : _client = client ?? http.Client();

  static final AuthService instance = AuthService._();

  static const String _tokenKey = 'ai_feynman.auth.token.v1';
  static const String _usernameKey = 'ai_feynman.auth.username.v1';

  final http.Client _client;

  String _token = '';
  String _username = '';
  bool _loaded = false;
  Future<void>? _pendingLoad;

  @visibleForTesting
  SharedPreferences? testPrefsOverride;

  Future<SharedPreferences> _obtainPrefs() async {
    if (testPrefsOverride != null) return testPrefsOverride!;
    return SharedPreferences.getInstance();
  }

  String get currentToken => _token;
  String get currentUsername => _username;
  bool get isLoggedIn => _token.isNotEmpty;
  bool get isLoaded => _loaded;
  String get storageNamespace {
    final name = _username.trim();
    return name.isEmpty
        ? 'guest'
        : name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  Future<void> load() async {
    if (_loaded) return;
    final pending = _pendingLoad;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _loadInternal();
    _pendingLoad = future;
    await future;
  }

  Future<void> _loadInternal() async {
    try {
      final prefs = await _obtainPrefs();
      _token = prefs.getString(_tokenKey) ?? '';
      _username = prefs.getString(_usernameKey) ?? '';
    } catch (e, st) {
      developer.log(
        'AuthService load failed; treating as logged out',
        name: 'ai_feynman.auth',
        error: e,
        stackTrace: st,
      );
      _token = '';
      _username = '';
    } finally {
      _loaded = true;
      _pendingLoad = null;
      await ProgressRepository.instance.switchUser(storageNamespace);
      await ReviewRepository.instance.switchUser(storageNamespace);
      notifyListeners();
    }
  }

  Future<AuthResult> register({
    required String username,
    required String password,
    String? grade,
  }) async {
    final outcome = await _post(
      '/auth/register',
      body: {
        'username': username,
        'password': password,
        if (grade != null) 'grade': grade,
      },
    );
    if (outcome is _ApiSuccess) {
      // 注册成功后自动登录，避免学生输入两次。
      return login(username: username, password: password);
    }
    final failure = outcome as _ApiFailure;
    return AuthResult.failure(failure.message);
  }

  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    final outcome = await _post(
      '/auth/login',
      body: {'username': username, 'password': password},
    );
    if (outcome is _ApiFailure) {
      return AuthResult.failure(outcome.message);
    }
    final success = outcome as _ApiSuccess;
    final body = success.body;
    final token = (body['token'] as String?) ?? '';
    final userMap = body['user'];
    final returnedName =
        userMap is Map<String, dynamic>
            ? (userMap['username'] as String? ?? username)
            : username;
    if (token.isEmpty) {
      return const AuthResult.failure('后端登录成功但没返回 token，请联系开发同学。');
    }
    _token = token;
    _username = returnedName;
    try {
      final prefs = await _obtainPrefs();
      await prefs.setString(_tokenKey, _token);
      await prefs.setString(_usernameKey, _username);
    } catch (e, st) {
      developer.log(
        'AuthService persist token failed',
        name: 'ai_feynman.auth',
        error: e,
        stackTrace: st,
      );
    }
    await ProgressRepository.instance.switchUser(storageNamespace);
    await ReviewRepository.instance.switchUser(storageNamespace);
    notifyListeners();
    return AuthResult.success(_username);
  }

  Future<void> logout() async {
    _token = '';
    _username = '';
    try {
      final prefs = await _obtainPrefs();
      await prefs.remove(_tokenKey);
      await prefs.remove(_usernameKey);
    } catch (_) {
      /* swallow */
    }
    await ProgressRepository.instance.switchUser(storageNamespace);
    await ReviewRepository.instance.switchUser(storageNamespace);
    notifyListeners();
  }

  Future<_ApiOutcome> _post(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    try {
      final resp = await _client
          .post(
            ApiConfig.uri(path),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode(body)),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          return _ApiSuccess(decoded);
        }
        return const _ApiFailure('后端返回格式不符合契约');
      }
      final detail = _extractDetail(resp.bodyBytes);
      return _ApiFailure(_humanize(resp.statusCode, detail));
    } on TimeoutException {
      return const _ApiFailure('网络超时，请稍后再试。');
    } on SocketException {
      return const _ApiFailure('连不上后端，请确认后端已启动。');
    } catch (e) {
      return _ApiFailure('请求失败：$e');
    }
  }

  static String _extractDetail(List<int> bytes) {
    try {
      final raw = utf8.decode(bytes);
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

  static String _humanize(int status, String detail) {
    if (status == 400 && detail.isNotEmpty) return detail;
    if (status == 401) return '账号或密码错误。';
    if (status == 422) return '输入字段不完整或格式错误。';
    if (status == 429) return '请求太频繁，喘口气再试。';
    if (status >= 500) return '后端暂时不可用（HTTP $status），请稍后再试。';
    return detail.isNotEmpty ? detail : '请求失败（HTTP $status）。';
  }

  /// 给学习同步、家长端等接口拼装 Authorization header。
  Map<String, String> authHeaders({Map<String, String>? base}) {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      ...?base,
    };
    if (_token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }
}

class AuthResult {
  const AuthResult.success(this.username) : ok = true, message = '';
  const AuthResult.failure(this.message) : ok = false, username = '';

  final bool ok;
  final String username;
  final String message;
}

sealed class _ApiOutcome {
  const _ApiOutcome();
}

class _ApiSuccess extends _ApiOutcome {
  const _ApiSuccess(this.body);
  final Map<String, dynamic> body;
}

class _ApiFailure extends _ApiOutcome {
  const _ApiFailure(this.message);
  final String message;
}
