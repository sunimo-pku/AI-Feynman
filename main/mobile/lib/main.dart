import 'package:flutter/material.dart';

import 'config/app_branding.dart';
import 'pages/auth_page.dart';
import 'pages/student_main_shell.dart';
import 'pages/parent_home_page.dart';
import 'services/auth_service.dart';
import 'services/learning_sync_service.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AiFeynmanApp());
}

class AiFeynmanApp extends StatefulWidget {
  const AiFeynmanApp({super.key});

  @override
  State<AiFeynmanApp> createState() => _AiFeynmanAppState();
}

class _AiFeynmanAppState extends State<AiFeynmanApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _routeResetScheduled = false;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_handleAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_handleAuthChanged);
    super.dispose();
  }

  void _handleAuthChanged() {
    final auth = AuthService.instance;
    if (!auth.isLoaded || auth.isLoggedIn || _routeResetScheduled) return;
    _routeResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeResetScheduled = false;
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: AppBranding.displayName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final Future<void> _bootFuture = _boot();

  Future<void> _boot() async {
    await AuthService.instance.load();
    if (AuthService.instance.isLoggedIn && AuthService.instance.isStudent) {
      LearningSyncService.instance.pullAndMerge();
    }
  }

  void _onAuthenticated() {
    if (AuthService.instance.isStudent) {
      LearningSyncService.instance.pullAndMerge();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return AnimatedBuilder(
          animation: AuthService.instance,
          builder: (context, _) {
            if (!AuthService.instance.isLoggedIn) {
              return AuthPage(
                showBackButton: false,
                onAuthenticated: _onAuthenticated,
              );
            }
            if (AuthService.instance.isParent) {
              return const ParentHomePage();
            }
            return const StudentMainShell();
          },
        );
      },
    );
  }
}
