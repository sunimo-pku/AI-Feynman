import 'dart:async';

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
import '../services/student_grade_store.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'curriculum_tab_page.dart';
import 'home_dashboard_tab.dart';
import 'lecture_page.dart';
import 'more_tab_page.dart';
// import 'privacy_notice_page.dart';
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
  int _pendingAssignments = 0;

  static const _tabTitles = ['今日', '课程', '工具', '我的'];

  @override
  void initState() {
    super.initState();
    ProgressRepository.instance.load();
    MockLectureRepository.instance.loadAssetBank().then((_) {
      if (mounted) setState(() {});
    });
    ReviewRepository.instance.load();
    AuthService.instance.load().then((_) async {
      if (AuthService.instance.isLoggedIn) {
        LearningSyncService.instance.pullAndMerge();
        await _syncStudentGrade();
        _loadPendingAssignments();
      }
    });
    StudentGradeStore.instance.addListener(_onGradeChanged);
  }

  @override
  void dispose() {
    StudentGradeStore.instance.removeListener(_onGradeChanged);
    _profileService.close();
    _assignmentService.close();
    super.dispose();
  }

  void _onGradeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _syncStudentGrade() async {
    await StudentGradeStore.instance.load();
    try {
      final profile = await _profileService.fetchProfile();
      await StudentGradeStore.instance.applyServerGrade(
        profile['grade'] as String?,
      );
    } catch (_) {
      /* 资料拉取失败时沿用本地已缓存年级 */
    }
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

  Future<void> _onOpenReviewBySectionId(String sectionId) async {
    final curriculum = await _curriculumFuture;
    CurriculumSection? target;
    outer:
    for (final book in curriculum.books) {
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          if (section.id == sectionId) {
            target = section;
            break outer;
          }
        }
      }
    }
    if (target == null) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReviewPage(section: target!)),
    );
    if (mounted) setState(() {});
  }


  List<CurriculumBook> _booksForGrade(
    MathCurriculum curriculum,
    String gradeLabel,
  ) {
    final books =
        curriculum.books
            .where((book) => book.gradeLabel == gradeLabel)
            .toList(growable: true);
    books.sort((a, b) => a.semester.compareTo(b.semester));
    return books;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: Text('AI 费曼 · ${_tabTitles[_tabIndex]}'),
      ),
      body: AnimatedBuilder(
        animation: StudentGradeStore.instance,
        builder: (context, _) {
          final gradeLabel = StudentGradeStore.instance.gradeLabel;
          if (!StudentGradeStore.instance.isLoaded || gradeLabel == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return FutureBuilder<MathCurriculum>(
            future: _curriculumFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('目录加载失败：${snapshot.error}'));
              }
              final curriculum = snapshot.data!;
              final visibleBooks = _booksForGrade(curriculum, gradeLabel);

              return IndexedStack(
                index: _tabIndex,
                children: [
                  HomeDashboardTab(
                    pendingAssignments: _pendingAssignments,
                    onAssignmentsTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const StudentAssignmentsPage(),
                        ),
                      );
                      await _loadPendingAssignments();
                    },
                    onOpenCurriculum: () => setState(() => _tabIndex = 1),
                    onOpenReview: _onOpenReviewBySectionId,
                  ),
                  CurriculumTabPage(
                    studentGradeLabel: gradeLabel,
                    books: visibleBooks,
                    onSectionTap: _onSectionTap,
                    onSectionReview: _onSectionReview,
                  ),
                  const MoreTabPage(),
                  PowerProfilePage(
                    embeddedInTab: true,
                    onProfileSaved: _syncStudentGrade,
                  ),
                ],
              );
            },
          );
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) {
          setState(() => _tabIndex = index);
          if (index == 3) {
            unawaited(_syncStudentGrade());
          }
        },
        destinations: [
          NavigationDestination(
            icon: StudyTabIcon(asset: 'assets/icons/tab_today.svg'),
            selectedIcon: StudyTabIcon(
              asset: 'assets/icons/tab_today.svg',
              selected: true,
            ),
            label: '今日',
          ),
          NavigationDestination(
            icon: StudyTabIcon(asset: 'assets/icons/tab_curriculum.svg'),
            selectedIcon: StudyTabIcon(
              asset: 'assets/icons/tab_curriculum.svg',
              selected: true,
            ),
            label: '课程',
          ),
          NavigationDestination(
            icon: StudyTabIcon(asset: 'assets/icons/tab_more.svg'),
            selectedIcon: StudyTabIcon(
              asset: 'assets/icons/tab_more.svg',
              selected: true,
            ),
            label: '工具',
          ),
          NavigationDestination(
            icon: StudyTabIcon(asset: 'assets/icons/tab_profile.svg'),
            selectedIcon: StudyTabIcon(
              asset: 'assets/icons/tab_profile.svg',
              selected: true,
            ),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
