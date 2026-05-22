import 'package:flutter/material.dart';

import 'parent_assignments_page.dart';
import 'parent_dashboard_page.dart';
import '../theme/app_theme.dart';

/// 家长端根页面：学习看板 + 作业 Tab。
class ParentHomePage extends StatefulWidget {
  const ParentHomePage({super.key});

  @override
  State<ParentHomePage> createState() => _ParentHomePageState();
}

class _ParentHomePageState extends State<ParentHomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      body: IndexedStack(
        index: _index,
        children: const [
          ParentDashboardPage(embedded: true),
          ParentAssignmentsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: '学习看板',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: '作业',
          ),
        ],
      ),
    );
  }
}
