import 'package:flutter/material.dart';

import 'pages/auth_page.dart';
import 'pages/home_page.dart';
import 'services/auth_service.dart';
import 'services/learning_sync_service.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AiFeynmanApp());
}

class AiFeynmanApp extends StatelessWidget {
  const AiFeynmanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 费曼',
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
    if (AuthService.instance.isLoggedIn) {
      LearningSyncService.instance.pullAndMerge();
    }
  }

  void _onAuthenticated() {
    LearningSyncService.instance.pullAndMerge();
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
            return const HomePage();
          },
        );
      },
    );
  }
}
