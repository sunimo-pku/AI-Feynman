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

/// 登录/注册 + token 持久化。
///
/// V2 账号模型：学生与家长均为独立账号，必须登录后使用 App（无游客）。
/// 家长账号登录时需额外提供「家长密码」；注册时需绑定已存在的学生用户名。
class AuthService extends ChangeNotifier {
  AuthService._({http.Client? client}) : _client = client ?? http.Client();

  static final AuthService instance = AuthService._();

  static const String _tokenKey = 'ai_feynman.auth.token.v1';
  static const String _usernameKey = 'ai_feynman.auth.username.v1';
  static const String _roleKey = 'ai_feynman.auth.role.v1';

  final http.Client _client;

  String _token = '';
  String _username = '';
  String _role = 'student';
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
  String get currentRole => _role;
  bool get isLoggedIn => _token.isNotEmpty;
  bool get isStudent => isLoggedIn && _role == 'student';
  bool get isParent => isLoggedIn && _role == 'parent';
  bool get isLoaded => _loaded;

  String get storageNamespace {
    final name = _username.trim();
    if (name.isEmpty) {
      throw StateError('storageNamespace requires a logged-in user');
    }
    return name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
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
      _role = prefs.getString(_roleKey) ?? 'student';
    } catch (e, st) {
      developer.log(
        'AuthService load failed; treating as logged out',
        name: 'ai_feynman.auth',
        error: e,
        stackTrace: st,
      );
      _token = '';
      _username = '';
      _role = 'student';
    } finally {
      _loaded = true;
      _pendingLoad = null;
      if (isLoggedIn) {
        await ProgressRepository.instance.switchUser(storageNamespace);
        await ReviewRepository.instance.switchUser(storageNamespace);
      }
      notifyListeners();
    }
  }

  Future<AuthResult> registerStudent({
    required String username,
    required String password,
    String? grade,
  }) {
    return register(
      username: username,
      password: password,
      role: 'student',
      grade: grade,
    );
  }

  Future<AuthResult> registerParent({
    required String username,
    required String password,
    required String parentPassword,
    required String childUsername,
  }) {
    return register(
      username: username,
      password: password,
      role: 'parent',
      parentPassword: parentPassword,
      childUsername: childUsername,
    );
  }

  Future<AuthResult> register({
    required String username,
    required String password,
    required String role,
    String? grade,
    String? parentPassword,
    String? childUsername,
  }) async {
    final body = <String, dynamic>{
      'username': username,
      'password': password,
      'role': role,
      if (grade != null) 'grade': grade,
      if (parentPassword != null) 'parentPassword': parentPassword,
      if (childUsername != null) 'childUsername': childUsername,
    };
    final outcome = await _post('/auth/register', body: body);
    if (outcome is _ApiSuccess) {
      return login(
        username: username,
        password: password,
        parentPassword: role == 'parent' ? parentPassword : null,
      );
    }
    final failure = outcome as _ApiFailure;
    return AuthResult.failure(failure.message);
  }

  Future<AuthResult> login({
    required String username,
    required String password,
    String? parentPassword,
  }) async {
    final body = <String, dynamic>{
      'username': username,
      'password': password,
      if (parentPassword != null && parentPassword.isNotEmpty)
        'parentPassword': parentPassword,
    };
    final outcome = await _post('/auth/login', body: body);
    if (outcome is _ApiFailure) {
      return AuthResult.failure(outcome.message);
    }
    final success = outcome as _ApiSuccess;
    final responseBody = success.body;
    final token = (responseBody['token'] as String?) ?? '';
    final userMap = responseBody['user'];
    final returnedName =
        userMap is Map<String, dynamic>
            ? (userMap['username'] as String? ?? username)
            : username;
    final returnedRole =
        userMap is Map<String, dynamic>
            ? (userMap['role'] as String? ?? 'student')
            : 'student';
    if (token.isEmpty) {
      return const AuthResult.failure('后端登录成功但没返回 token，请联系开发同学。');
    }
    _token = token;
    _username = returnedName;
    _role = returnedRole;
    try {
      final prefs = await _obtainPrefs();
      await prefs.setString(_tokenKey, _token);
      await prefs.setString(_usernameKey, _username);
      await prefs.setString(_roleKey, _role);
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
    return AuthResult.success(_username, role: _role);
  }

  Future<void> logout() async {
    _token = '';
    _username = '';
    _role = 'student';
    try {
      final prefs = await _obtainPrefs();
      await prefs.remove(_tokenKey);
      await prefs.remove(_usernameKey);
      await prefs.remove(_roleKey);
    } catch (_) {
      /* swallow */
    }
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
    if (status == 401) {
      if (detail.contains('Parent password')) return '家长密码错误或未填写。';
      return detail.isNotEmpty ? detail : '账号或密码错误。';
    }
    if (status == 403 && detail.isNotEmpty) return detail;
    if (status == 404 && detail.isNotEmpty) return detail;
    if (status == 422) return '输入字段不完整或格式错误。';
    if (status == 429) return '请求太频繁，喘口气再试。';
    if (status >= 500) return '后端暂时不可用（HTTP $status），请稍后再试。';
    return detail.isNotEmpty ? detail : '请求失败（HTTP $status）。';
  }

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
  const AuthResult.success(this.username, {this.role = 'student'})
    : ok = true,
      message = '';

  const AuthResult.failure(this.message) : ok = false, username = '', role = 'student';

  final bool ok;
  final String username;
  final String role;
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
