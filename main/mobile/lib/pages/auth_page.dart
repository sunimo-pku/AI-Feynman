import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// 登录 / 注册页（第十轮）。
///
/// 设计：
///   * 单页 + tab 切换「登录 / 注册」，不开二级路由，迁回首页只 Navigator.pop()。
///   * 校验最轻：用户名 3-32、密码 ≥ 6。后端会再校验一次。
///   * 失败原因显示在表单下方的红色提示条，可点重试。
///   * 登录成功后 pop(true)，调用方据此触发同步 / 跳家长端等下一步动作。
class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.initialMode = AuthPageMode.login});

  final AuthPageMode initialMode;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

enum AuthPageMode { login, register }

class _AuthPageState extends State<AuthPage> with TickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialMode == AuthPageMode.register ? 1 : 0,
    );
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() => _errorMessage = null);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (_submitting) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.length < 3 || username.length > 32) {
      setState(() => _errorMessage = '用户名 3-32 个字符。');
      return;
    }
    if (password.length < 6) {
      setState(() => _errorMessage = '密码至少 6 位。');
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final isLogin = _tabController.index == 0;
    final result = isLogin
        ? await AuthService.instance.login(
            username: username,
            password: password,
          )
        : await AuthService.instance.register(
            username: username,
            password: password,
          );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (!result.ok) {
      setState(() => _errorMessage = result.message);
      return;
    }
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: const Text('登录 · 同步学习数据'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.pageEdge),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '登录后可在不同设备之间同步学习进度，\n'
                    '家长端也可以查看孩子的弱项和最近讲题。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppPalette.textSecondary,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.moduleGap),
                  TabBar(
                    controller: _tabController,
                    labelColor: AppPalette.primary,
                    unselectedLabelColor: AppPalette.textSecondary,
                    indicatorColor: AppPalette.primary,
                    tabs: const [
                      Tab(text: '登录'),
                      Tab(text: '注册'),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.moduleGap),
                  _Field(
                    controller: _usernameController,
                    label: '用户名（3-32 位字母 / 数字）',
                    autofillHints: const [AutofillHints.username],
                    keyboardType: TextInputType.text,
                  ),
                  const SizedBox(height: AppSpacing.itemGap),
                  _Field(
                    controller: _passwordController,
                    label: '密码（≥ 6 位）',
                    obscure: true,
                    autofillHints: const [AutofillHints.password],
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.itemGap),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.error.withValues(alpha: 0.08),
                        borderRadius: AppRadius.buttonR,
                        border: Border.all(
                          color: AppPalette.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: AppPalette.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.moduleGap),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _onSubmit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.lock_open_outlined, size: 16),
                    label: Text(_tabController.index == 0 ? '登录' : '注册并登录'),
                  ),
                  const SizedBox(height: AppSpacing.tightGap),
                  Text(
                    '提示：可以用任意 3-32 位用户名 + 6 位以上密码注册新账号。'
                    '示例：xiaoming123 / abcdef123。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.obscure = false,
    this.autofillHints,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final Iterable<String>? autofillHints;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofillHints: autofillHints,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: AppPalette.surface,
        border: const OutlineInputBorder(
          borderRadius: AppRadius.buttonR,
          borderSide: BorderSide(color: AppPalette.outline),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.buttonR,
          borderSide: BorderSide(color: AppPalette.outline),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.buttonR,
          borderSide: BorderSide(color: AppPalette.primary, width: 1.6),
        ),
      ),
    );
  }
}
