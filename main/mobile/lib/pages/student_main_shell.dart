import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../data/mock_lecture_repository.dart';
import '../services/assignment_service.dart';
import '../services/auth_service.dart';
import '../services/learning_sync_service.dart';
import '../services/progress_repository.dart';
import '../services/review_repository.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import 'curriculum_tab_page.dart';
import 'home_dashboard_tab.dart';
import 'lecture_page.dart';
import 'more_tab_page.dart';
import 'privacy_notice_page.dart';
import 'review_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

/// 学生端主壳：底部四 Tab，避免单页堆叠整册目录。
class StudentMainShell extends StatefulWidget {
  const StudentMainShell({super.key});

  @override
  State<StudentMainShell> createState() => _StudentMainShellState();
}

/// 兼容旧入口命名。
typedef HomePage = StudentMainShell;

class _StudentMainShellState extends State<StudentMainShell> {
  late final Future<MathCurriculum> _curriculumFuture =
      CurriculumRepository.instance.load();
  final Round12Service _profileService = Round12Service();
  final AssignmentService _assignmentService = AssignmentService();

  int _tabIndex = 0;
  String _studentGradeLabel = '八年级';
  int _pendingAssignments = 0;

  static const _tabTitles = ['今日', '课程', '更多', '我的'];

  @override
  void initState() {
    super.initState();
    ProgressRepository.instance.load();
    MockLectureRepository.instance.loadAssetBank().then((_) {
      if (mounted) setState(() {});
    });
    ReviewRepository.instance.load();
    AuthService.instance.load().then((_) {
      if (AuthService.instance.isLoggedIn) {
        LearningSyncService.instance.pullAndMerge();
        _loadStudentGrade();
        _loadPendingAssignments();
      }
    });
  }

  @override
  void dispose() {
    _profileService.close();
    _assignmentService.close();
    super.dispose();
  }

  Future<void> _loadPendingAssignments() async {
    if (!AuthService.instance.isLoggedIn || !AuthService.instance.isStudent) {
      return;
    }
    try {
      final result = await _assignmentService.fetchStudentAssignments();
      if (!mounted) return;
      setState(() => _pendingAssignments = result.pendingCount);
    } catch (_) {}
  }

  Future<void> _loadStudentGrade() async {
    try {
      final profile = await _profileService.fetchProfile();
      final grade = (profile['grade'] as String? ?? '').trim();
      if (!mounted || grade.isEmpty) return;
      setState(() => _studentGradeLabel = grade);
    } catch (_) {}
  }

  Future<void> _onSectionTap(CurriculumSection section) async {
    final hasQuestion =
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    if (section.isAvailable || hasQuestion) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => LecturePage(section: section)));
      if (mounted) setState(() {});
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这一节正在整理练习内容，先选一个可练习小节开始吧。')),
    );
  }

  Future<void> _onSectionReview(CurriculumSection section) async {
    if (!section.isAvailable &&
        MockLectureRepository.instance.questionCountForSection(section.id) <=
            0) {
      return;
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ReviewPage(section: section)));
    if (mounted) setState(() {});
  }

  Future<void> _onLogout() async {
    await AuthService.instance.logout();
  }

  List<CurriculumBook> _booksForGrade(MathCurriculum curriculum) {
    final matched =
        curriculum.books
            .where((book) => book.gradeLabel == _studentGradeLabel)
            .toList(growable: false);
    return matched.isEmpty ? curriculum.books : matched;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: Text('AI 费曼 · ${_tabTitles[_tabIndex]}'),
        actions: [
          AnimatedBuilder(
            animation: AuthService.instance,
            builder: (_, __) {
              final username = AuthService.instance.currentUsername;
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(
                  child: _StudentAccountChip(
                    label: username.isEmpty ? '学生' : username,
                    onLogout: _onLogout,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '隐私说明',
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PrivacyNoticePage()),
                ),
            icon: const Icon(Icons.privacy_tip_outlined),
          ),
        ],
      ),
      body: FutureBuilder<MathCurriculum>(
        future: _curriculumFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('目录加载失败：${snapshot.error}'));
          }
          final curriculum = snapshot.data!;
          final visibleBooks = _booksForGrade(curriculum);

          return IndexedStack(
            index: _tabIndex,
            children: [
              HomeDashboardTab(
                curriculum: curriculum,
                studentGradeLabel: _studentGradeLabel,
                books: visibleBooks,
                pendingAssignments: _pendingAssignments,
                onSectionTap: _onSectionTap,
                onAssignmentsTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const StudentAssignmentsPage(),
                    ),
                  );
                  await _loadPendingAssignments();
                },
              ),
              CurriculumTabPage(
                curriculum: curriculum,
                initialGradeLabel: _studentGradeLabel,
                onSectionTap: _onSectionTap,
                onSectionReview: _onSectionReview,
                onGradeChanged: (grade) {
                  setState(() => _studentGradeLabel = grade);
                },
              ),
              const MoreTabPage(),
              const PowerProfilePage(embeddedInTab: true),
            ],
          );
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '课程',
          ),
          NavigationDestination(
            icon: Icon(Icons.apps_outlined),
            selectedIcon: Icon(Icons.apps),
            label: '更多',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class _StudentAccountChip extends StatelessWidget {
  const _StudentAccountChip({required this.label, required this.onLogout});

  final String label;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '账号',
      onSelected: (key) {
        if (key == 'logout') onLogout();
      },
      itemBuilder:
          (_) => const [PopupMenuItem(value: 'logout', child: Text('退出登录'))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppPalette.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppPalette.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.school_outlined,
              size: 14,
              color: AppPalette.primary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: AppPalette.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
