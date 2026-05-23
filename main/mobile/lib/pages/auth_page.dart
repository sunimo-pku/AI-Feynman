import 'package:flutter/material.dart';

import '../config/app_branding.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// 登录 / 注册页。
///
/// 一个账号两套密码：注册时填写账号密码 + 家长密码；登录时选择进入学生端或家长端。
class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    this.initialMode = AuthPageMode.login,
    this.showBackButton = true,
    this.onAuthenticated,
  });

  final AuthPageMode initialMode;
  final bool showBackButton;
  final VoidCallback? onAuthenticated;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

enum AuthPageMode { login, register }

enum AuthLoginPortal { student, parent }

const List<String> _gradeOptions = <String>['七年级', '八年级', '九年级'];

class _AuthPageState extends State<AuthPage> with TickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _parentPasswordController = TextEditingController();
  AuthLoginPortal _loginPortal = AuthLoginPortal.student;
  String _selectedGrade = '八年级';

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
    _parentPasswordController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (_submitting) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final parentPassword = _parentPasswordController.text;
    if (username.length < 3 || username.length > 32) {
      setState(() => _errorMessage = '用户名 3-32 个字符。');
      return;
    }
    if (password.length < 6) {
      setState(() => _errorMessage = '账号密码至少 6 位。');
      return;
    }
    final isLogin = _tabController.index == 0;
    if (!isLogin && parentPassword.length < 6) {
      setState(() => _errorMessage = '家长密码至少 6 位。');
      return;
    }
    if (isLogin &&
        _loginPortal == AuthLoginPortal.parent &&
        parentPassword.length < 6) {
      setState(() => _errorMessage = '进入家长端需填写家长密码。');
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final AuthResult result;
    if (isLogin) {
      result = await AuthService.instance.login(
        username: username,
        password: password,
        loginAs:
            _loginPortal == AuthLoginPortal.parent ? 'parent' : 'student',
        parentPassword:
            _loginPortal == AuthLoginPortal.parent ? parentPassword : null,
      );
    } else {
      result = await AuthService.instance.register(
        username: username,
        password: password,
        parentPassword: parentPassword,
        grade: _selectedGrade,
      );
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (!result.ok) {
      setState(() => _errorMessage = result.message);
      return;
    }
    final callback = widget.onAuthenticated;
    if (callback != null) {
      callback();
    } else if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoginParent =
        _tabController.index == 0 && _loginPortal == AuthLoginPortal.parent;
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBackButton,
        title: const Text(AppBranding.displayName),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.pageEdge),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _AuthHeader(),
                    const SizedBox(height: AppSpacing.moduleGap),
                    TabBar(
                      controller: _tabController,
                      labelColor: AppPalette.primary,
                      unselectedLabelColor: AppPalette.textSecondary,
                      indicatorColor: AppPalette.primary,
                      tabs: const [Tab(text: '登录'), Tab(text: '注册')],
                    ),
                    const SizedBox(height: AppSpacing.itemGap),
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        if (_tabController.index != 0) {
                          return const SizedBox.shrink();
                        }
                        return SegmentedButton<AuthLoginPortal>(
                          segments: const [
                            ButtonSegment(
                              value: AuthLoginPortal.student,
                              label: Text('学生端'),
                              icon: Icon(Icons.school_outlined, size: 16),
                            ),
                            ButtonSegment(
                              value: AuthLoginPortal.parent,
                              label: Text('家长端'),
                              icon: Icon(Icons.family_restroom_outlined, size: 16),
                            ),
                          ],
                          selected: {_loginPortal},
                          onSelectionChanged: (selected) {
                            setState(() {
                              _loginPortal = selected.first;
                              _errorMessage = null;
                            });
                          },
                        );
                      },
                    ),
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        if (_tabController.index != 0) {
                          return const SizedBox.shrink();
                        }
                        return const SizedBox(height: AppSpacing.moduleGap);
                      },
                    ),
                    _Field(
                      controller: _usernameController,
                      label: '用户名（3-32 位字母 / 数字）',
                      autofillHints: const [AutofillHints.username],
                    ),
                    const SizedBox(height: AppSpacing.itemGap),
                    _Field(
                      controller: _passwordController,
                      label: '账号密码（≥ 6 位）',
                      obscure: true,
                      autofillHints: const [AutofillHints.password],
                    ),
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        final showParentField =
                            _tabController.index == 1 || isLoginParent;
                        if (!showParentField) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.itemGap),
                          child: _Field(
                            controller: _parentPasswordController,
                            label:
                                _tabController.index == 0
                                    ? '家长密码（进入家长端）'
                                    : '家长密码（≥ 6 位，仅家长端使用）',
                            obscure: true,
                          ),
                        );
                      },
                    ),
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        if (_tabController.index != 1) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.itemGap),
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedGrade,
                            decoration: const InputDecoration(
                              labelText: '当前年级',
                              filled: true,
                              fillColor: AppPalette.surface,
                              border: OutlineInputBorder(
                                borderRadius: AppRadius.buttonR,
                                borderSide: BorderSide(color: AppPalette.outline),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: AppRadius.buttonR,
                                borderSide: BorderSide(color: AppPalette.outline),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: AppRadius.buttonR,
                                borderSide: BorderSide(
                                  color: AppPalette.primary,
                                  width: 1.6,
                                ),
                              ),
                            ),
                            items:
                                _gradeOptions
                                    .map(
                                      (grade) => DropdownMenuItem(
                                        value: grade,
                                        child: Text(grade),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                (value) => setState(
                                  () => _selectedGrade = value ?? _selectedGrade,
                                ),
                          ),
                        );
                      },
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
                      icon:
                          _submitting
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
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        final hint =
                            _tabController.index == 0
                                ? '同一账号：学生端用账号密码；家长端额外填写家长密码。'
                                : '注册一次即可：账号密码给孩子讲题，家长密码给家长查看报告。';
                        return Text(
                          hint,
                          style: Theme.of(context).textTheme.bodySmall,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthHeader extends StatelessWidget {
  const _AuthHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.largeR,
        boxShadow: AppShadows.paper,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppPalette.primary.withValues(alpha: 0.10),
              borderRadius: AppRadius.buttonR,
            ),
            child: const Icon(Icons.school_outlined, color: AppPalette.primary),
          ),
          const SizedBox(height: 16),
          Text(AppBranding.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            AppBranding.tagline,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.primary),
          ),
          const SizedBox(height: 12),
          Text(
            '一个家庭一个账号。注册时设置账号密码与家长密码；登录时再选学生端或家长端。',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
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
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofillHints: autofillHints,
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
