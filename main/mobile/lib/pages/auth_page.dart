import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// 登录 / 注册页。
///
/// 学生与家长为独立账号：学生仅需账号密码；家长额外需要「家长密码」。
/// 家长注册时需填写已注册的学生用户名，系统建立 1:1 绑定。
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

enum AuthAccountKind { student, parent }

const List<String> _gradeOptions = <String>['七年级', '八年级', '九年级'];

class _AuthPageState extends State<AuthPage> with TickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _parentPasswordController = TextEditingController();
  final TextEditingController _childUsernameController = TextEditingController();
  AuthAccountKind _accountKind = AuthAccountKind.student;
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
    _childUsernameController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (_submitting) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final parentPassword = _parentPasswordController.text;
    final childUsername = _childUsernameController.text.trim();
    if (username.length < 3 || username.length > 32) {
      setState(() => _errorMessage = '用户名 3-32 个字符。');
      return;
    }
    if (password.length < 6) {
      setState(() => _errorMessage = '密码至少 6 位。');
      return;
    }
    if (_accountKind == AuthAccountKind.parent) {
      if (parentPassword.length < 6) {
        setState(() => _errorMessage = '家长密码至少 6 位。');
        return;
      }
      if (_tabController.index == 1 && childUsername.length < 3) {
        setState(() => _errorMessage = '请填写已注册的学生用户名。');
        return;
      }
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final isLogin = _tabController.index == 0;
    final AuthResult result;
    if (isLogin) {
      result = await AuthService.instance.login(
        username: username,
        password: password,
        parentPassword:
            _accountKind == AuthAccountKind.parent ? parentPassword : null,
      );
    } else if (_accountKind == AuthAccountKind.parent) {
      result = await AuthService.instance.registerParent(
        username: username,
        password: password,
        parentPassword: parentPassword,
        childUsername: childUsername,
      );
    } else {
      result = await AuthService.instance.registerStudent(
        username: username,
        password: password,
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
    final isParent = _accountKind == AuthAccountKind.parent;
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBackButton,
        title: const Text('AI 费曼'),
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
                    SegmentedButton<AuthAccountKind>(
                      segments: const [
                        ButtonSegment(
                          value: AuthAccountKind.student,
                          label: Text('学生账号'),
                          icon: Icon(Icons.school_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: AuthAccountKind.parent,
                          label: Text('家长账号'),
                          icon: Icon(Icons.family_restroom_outlined, size: 16),
                        ),
                      ],
                      selected: {_accountKind},
                      onSelectionChanged: (selected) {
                        setState(() {
                          _accountKind = selected.first;
                          _errorMessage = null;
                        });
                      },
                    ),
                    const SizedBox(height: AppSpacing.moduleGap),
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
                    if (isParent) ...[
                      const SizedBox(height: AppSpacing.itemGap),
                      _Field(
                        controller: _parentPasswordController,
                        label: '家长密码（≥ 6 位，仅家长端使用）',
                        obscure: true,
                      ),
                    ],
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        if (_tabController.index == 0 || !isParent) {
                          if (_tabController.index == 1 &&
                              _accountKind == AuthAccountKind.student) {
                            return Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.itemGap,
                              ),
                              child: DropdownButtonFormField<String>(
                                initialValue: _selectedGrade,
                                decoration: const InputDecoration(
                                  labelText: '当前年级',
                                  filled: true,
                                  fillColor: AppPalette.surface,
                                  border: OutlineInputBorder(
                                    borderRadius: AppRadius.buttonR,
                                    borderSide: BorderSide(
                                      color: AppPalette.outline,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: AppRadius.buttonR,
                                    borderSide: BorderSide(
                                      color: AppPalette.outline,
                                    ),
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
                                      () =>
                                          _selectedGrade =
                                              value ?? _selectedGrade,
                                    ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.itemGap),
                          child: _Field(
                            controller: _childUsernameController,
                            label: '孩子用户名（须先注册学生账号）',
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
                    Text(
                      isParent
                          ? '家长账号与孩子账号一一对应。注册家长时需填写已存在的学生用户名。'
                          : '请先注册学生账号，再为孩子创建对应的家长账号。',
                      style: Theme.of(context).textTheme.bodySmall,
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
        border: Border.all(color: AppPalette.outlineSoft),
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
          Text('登录后开始学习', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '学生与家长均需登录。家长使用独立账号 + 家长密码查看孩子的学习报告。',
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
