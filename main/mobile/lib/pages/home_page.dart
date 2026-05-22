import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../data/mock_lecture_repository.dart';
import '../data/progress_models.dart';
import '../services/assignment_service.dart';
import '../services/auth_service.dart';
import '../services/learning_sync_service.dart';
import '../services/progress_repository.dart';
import '../services/review_repository.dart';
import '../services/round12_service.dart';
import '../theme/app_theme.dart';
import '../widgets/study_layout.dart';
import 'daily_challenge_page.dart';
import 'lecture_page.dart';
import 'privacy_notice_page.dart';
import 'review_page.dart';
import 'student_assignments_page.dart';
import 'v2_pages.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Future<MathCurriculum> _curriculumFuture =
      CurriculumRepository.instance.load();
  final Round12Service _profileService = Round12Service();
  final AssignmentService _assignmentService = AssignmentService();
  String _studentGradeLabel = '八年级';
  int _pendingAssignments = 0;

  @override
  void initState() {
    super.initState();
    // 第六轮：异步预热本地进度仓库。任何失败都被仓库吞掉打 log，
    // 这里不阻塞课程目录展示 —— FutureBuilder 仍以 curriculum 为主线。
    // 仓库本身是 ChangeNotifier，加载成功后 _ProgressAwareSectionPill 会
    // 自动重建展示「已完成 N 轮 · 掌握度 X/100」。
    ProgressRepository.instance.load();
    MockLectureRepository.instance.loadAssetBank().then((_) {
      if (mounted) setState(() {});
    });
    // 第八轮：预热回顾仓库，让小节 pill 上的「回顾」入口能立即反映「有/无
    // 历史记录」。失败同样被仓库吞掉打 log，不阻塞首页。
    ReviewRepository.instance.load();
    // 第十轮：预热登录态。已登录则触发一次本地 → 后端同步，让登录
    // 不在 UI 上有任何感知（无 loading 阻塞）。
    AuthService.instance.load().then((_) {
      if (AuthService.instance.isLoggedIn) {
        // 静默同步：失败仅在 sync service 的 lastError 里暴露。
        LearningSyncService.instance.pullAndMerge();
        _loadStudentGrade();
        _loadPendingAssignments();
      }
    });
  }

  Future<void> _loadPendingAssignments() async {
    if (!AuthService.instance.isLoggedIn || !AuthService.instance.isStudent) {
      return;
    }
    try {
      final result = await _assignmentService.fetchStudentAssignments();
      if (!mounted) return;
      setState(() => _pendingAssignments = result.pendingCount);
    } catch (_) {
      // 作业条是增强入口，失败不阻塞首页。
    }
  }

  @override
  void dispose() {
    _profileService.close();
    _assignmentService.close();
    super.dispose();
  }

  Future<void> _loadStudentGrade() async {
    try {
      final profile = await _profileService.fetchProfile();
      final grade = (profile['grade'] as String? ?? '').trim();
      if (!mounted || grade.isEmpty) return;
      setState(() => _studentGradeLabel = grade);
    } catch (_) {
      // 年级只影响目录默认展示，失败时保留八年级默认值，不阻塞首页。
    }
  }

  Future<void> _onSectionTap(CurriculumSection section) async {
    final hasQuestion =
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    if (section.isAvailable || hasQuestion) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => LecturePage(section: section)));
      // 第六轮：从讲题页返回后强制 setState 触发首页重建。
      // 仓库在 completed 时已经 notifyListeners，AnimatedBuilder 会自动
      // 刷新进度徽标；这里多做一次 setState 是为了万一返回路径里 progress
      // 还没写盘完成（异步），下一帧仍能拿到最新缓存。
      if (mounted) setState(() {});
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('这一节正在整理练习内容，先选一个可练习小节开始吧。')));
  }

  Future<void> _onLogout() async {
    await AuthService.instance.logout();
  }

  /// 第八轮：从首页进入指定小节的讲题回顾页。
  ///
  /// 只对 `available` 的小节开放（未上线小节既没法练习也没法回顾，避免
  /// 在置灰 pill 旁边放一个能点进去的「回顾」按钮造成迷惑）。
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

  @override
  Widget build(BuildContext context) {
    return StudyShell(
      title: 'AI 费曼 · 初中数学自习室',
      maxWidth: 1180,
      actions: [
        AnimatedBuilder(
          animation: AuthService.instance,
          builder: (_, __) {
            final username = AuthService.instance.currentUsername;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
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
        const SizedBox(width: 10),
      ],
      child: FutureBuilder<MathCurriculum>(
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
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _HeroBanner(
                curriculum: curriculum,
                studentGradeLabel: _studentGradeLabel,
              ),
              if (_pendingAssignments > 0) ...[
                const SizedBox(height: AppSpacing.itemGap),
                _PendingAssignmentsBanner(
                  count: _pendingAssignments,
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const StudentAssignmentsPage()),
                    );
                    await _loadPendingAssignments();
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.moduleGap),
              _TodayStudyCard(
                curriculum: curriculum,
                books: visibleBooks,
                onSectionTap: _onSectionTap,
              ),
              const SizedBox(height: AppSpacing.moduleGap),
              const _LearningToolsSection(),
              const SizedBox(height: AppSpacing.moduleGap),
              StudyPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeader(
                      title: '课程目录',
                      subtitle: '默认展示 $_studentGradeLabel 上下册；年级可在「我的成长」资料页修改。',
                      icon: Icons.library_books_outlined,
                    ),
                    const SizedBox(height: 14),
                    ...visibleBooks.map(
                      (book) => Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.itemGap,
                        ),
                        child: _BookCard(
                          book: book,
                          onSectionTap: _onSectionTap,
                          onSectionReview: _onSectionReview,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<CurriculumBook> _booksForGrade(MathCurriculum curriculum) {
    final matched = curriculum.books
        .where((book) => book.gradeLabel == _studentGradeLabel)
        .toList(growable: false);
    return matched.isEmpty ? curriculum.books : matched;
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({
    required this.curriculum,
    required this.studentGradeLabel,
  });

  final MathCurriculum curriculum;
  final String studentGradeLabel;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      tone: StudyPanelTone.primary,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      radius: AppRadius.largeR,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '把题讲明白，才是真的会',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${curriculum.publisher} · $studentGradeLabel${curriculum.subjectLabel}练习。'
                      '写步骤、开口讲，AI 同伴会追问你的依据、条件和易错点。',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppPalette.surface,
                  borderRadius: AppRadius.largeR,
                  border: Border.all(color: AppPalette.outlineSoft),
                ),
                child: const Icon(
                  Icons.edit_note_outlined,
                  size: 44,
                  color: AppPalette.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Tag(label: '全册可练', color: AppPalette.primary, filled: true),
              _Tag(label: '手写讲题', color: AppPalette.primaryAccent),
              _Tag(label: '语音追问', color: AppPalette.primaryAccent),
              _Tag(label: '家长报告', color: AppPalette.primaryAccent),
            ],
          ),
        ],
      ),
    );
  }
}

class _TodayStudyCard extends StatelessWidget {
  const _TodayStudyCard({
    required this.curriculum,
    required this.books,
    required this.onSectionTap,
  });

  final MathCurriculum curriculum;
  final List<CurriculumBook> books;
  final ValueChanged<CurriculumSection> onSectionTap;

  @override
  Widget build(BuildContext context) {
    final recommended = _recommendedSection();
    final questionCount =
        recommended == null
            ? 0
            : MockLectureRepository.instance.questionCountForSection(
              recommended.id,
            );
    return StudyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '今日继续学习',
            subtitle:
                recommended == null ? '题库正在准备中。' : '建议先完成一题，再回看 AI 同伴的追问。',
            icon: Icons.school_outlined,
            action:
                recommended == null
                    ? null
                    : FilledButton.icon(
                      onPressed: () => onSectionTap(recommended),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始讲题'),
                    ),
          ),
          const SizedBox(height: 16),
          if (recommended == null)
            Text('暂时没有可练小节。', style: Theme.of(context).textTheme.bodyMedium)
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StudyStatPill(
                  label: '推荐小节',
                  value: recommended.label,
                  icon: Icons.auto_awesome_outlined,
                ),
                StudyStatPill(
                  label: '题目数量',
                  value: questionCount > 0 ? '$questionCount 道题' : '可练习',
                  icon: Icons.edit_note_outlined,
                  accent: AppPalette.primaryAccent,
                ),
                AnimatedBuilder(
                  animation: ProgressRepository.instance,
                  builder: (context, _) {
                    final progress = ProgressRepository.instance.progressFor(
                      recommended.id,
                    );
                    return StudyStatPill(
                      label: '当前掌握',
                      value:
                          !progress.hasAnyCompletion
                              ? '未开始'
                              : '${progress.masteryScore}/100',
                      icon: Icons.insights_outlined,
                      accent: AppPalette.primary,
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }

  CurriculumSection? _recommendedSection() {
    for (final book in books) {
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          final hasQuestion =
              MockLectureRepository.instance.questionCountForSection(
                section.id,
              ) >
              0;
          if (section.isAvailable || hasQuestion) {
            return section;
          }
        }
      }
    }
    return null;
  }
}

class _LearningToolsSection extends StatelessWidget {
  const _LearningToolsSection();

  @override
  Widget build(BuildContext context) {
    final entries = <_LearningToolEntry>[
      _LearningToolEntry(
        '我的作业',
        Icons.assignment_outlined,
        () => const StudentAssignmentsPage(),
      ),
      _LearningToolEntry(
        '每日挑战',
        Icons.where_to_vote_outlined,
        () => const DailyChallengePage(),
      ),
      _LearningToolEntry(
        '晶石奖励',
        Icons.diamond_outlined,
        () => const ShopPage(),
      ),
      _LearningToolEntry(
        '学习榜单',
        Icons.emoji_events_outlined,
        () => const LeaderboardPage(),
      ),
      _LearningToolEntry(
        '拍照识题',
        Icons.document_scanner_outlined,
        () => const PhotoQuestionPage(),
      ),
      _LearningToolEntry(
        '我的成长',
        Icons.bolt_outlined,
        () => const PowerProfilePage(),
      ),
    ];
    return StudyPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '学习工具',
            subtitle: '挑战、回顾、奖励和家长报告都收在这里，不抢主学习路径。',
            icon: Icons.dashboard_customize_outlined,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children:
                entries.map((e) => _LearningToolButton(entry: e)).toList(),
          ),
        ],
      ),
    );
  }
}

class _LearningToolButton extends StatelessWidget {
  const _LearningToolButton({required this.entry});

  final _LearningToolEntry entry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 158,
      child: Material(
        color: AppPalette.primary.withValues(alpha: 0.06),
        borderRadius: AppRadius.buttonR,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap:
              () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => entry.builder())),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: AppRadius.buttonR,
              border: Border.all(
                color: AppPalette.primary.withValues(alpha: 0.14),
              ),
            ),
            child: Row(
              children: [
                Icon(entry.icon, size: 18, color: AppPalette.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.label,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: AppPalette.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LearningToolEntry {
  const _LearningToolEntry(this.label, this.icon, this.builder);
  final String label;
  final IconData icon;
  final Widget Function() builder;
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color, this.filled = false});

  final String label;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: filled ? Colors.white : color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 首页 AppBar 上的学生账号与退出入口。
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

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onSectionTap,
    required this.onSectionReview,
  });

  final CurriculumBook book;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;

  @override
  Widget build(BuildContext context) {
    final hasAvailable = book.chapters.any(
      (c) => c.sections.any(
        (s) =>
            s.isAvailable ||
            MockLectureRepository.instance.questionCountForSection(s.id) > 0,
      ),
    );
    return StudyPanel(
      tone: StudyPanelTone.quiet,
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: hasAvailable,
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          title: Text(
            book.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasAvailable ? '本册可练习' : '内容整理中',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    hasAvailable
                        ? AppPalette.primaryAccent
                        : AppPalette.comingSoon,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          children:
              book.chapters.map((chapter) {
                return _ChapterBlock(
                  chapter: chapter,
                  onSectionTap: onSectionTap,
                  onSectionReview: onSectionReview,
                );
              }).toList(),
        ),
      ),
    );
  }
}

class _ChapterBlock extends StatelessWidget {
  const _ChapterBlock({
    required this.chapter,
    required this.onSectionTap,
    required this.onSectionReview,
  });

  final CurriculumChapter chapter;
  final ValueChanged<CurriculumSection> onSectionTap;
  final ValueChanged<CurriculumSection> onSectionReview;

  @override
  Widget build(BuildContext context) {
    final chapterAvailable = chapter.sections.any(
      (s) =>
          s.isAvailable ||
          MockLectureRepository.instance.questionCountForSection(s.id) > 0,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                chapter.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color:
                      chapterAvailable
                          ? AppPalette.textPrimary
                          : AppPalette.comingSoon,
                ),
              ),
              if (!chapterAvailable) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: AppPalette.comingSoon,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                chapter.sections
                    .map(
                      (s) => _SectionPill(
                        section: s,
                        onTap: onSectionTap,
                        onReview: onSectionReview,
                      ),
                    )
                    .toList(),
          ),
        ],
      ),
    );
  }
}

class _SectionPill extends StatelessWidget {
  const _SectionPill({
    required this.section,
    required this.onTap,
    required this.onReview,
  });

  final CurriculumSection section;
  final ValueChanged<CurriculumSection> onTap;
  final ValueChanged<CurriculumSection> onReview;

  @override
  Widget build(BuildContext context) {
    final available =
        section.isAvailable ||
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    // 第六轮：可练习小节订阅 ProgressRepository，展示「已完成 N 轮 · 掌握度
    // X/100」。未上线小节仍保持原样，不挂订阅、不展示进度。
    if (!available) {
      return _buildPill(context, progress: null);
    }
    // 第八轮：同时订阅 ReviewRepository，让「回顾」入口在写入新记录后
    // 立即从灰色变为可点击。两个 ChangeNotifier 用 Listenable.merge 合并,
    // 避免嵌套两层 AnimatedBuilder。
    return AnimatedBuilder(
      animation: Listenable.merge([
        ProgressRepository.instance,
        ReviewRepository.instance,
      ]),
      builder: (context, _) {
        final progress = ProgressRepository.instance.progressFor(section.id);
        return _buildPill(context, progress: progress);
      },
    );
  }

  Widget _buildPill(
    BuildContext context, {
    required SectionProgress? progress,
  }) {
    final available =
        section.isAvailable ||
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    final hasProgress = progress != null && progress.hasAnyCompletion;
    final bg =
        available
            ? AppPalette.primary.withValues(alpha: 0.08)
            : AppPalette.comingSoon.withValues(alpha: 0.08);
    final border =
        available
            ? AppPalette.primary.withValues(alpha: 0.4)
            : AppPalette.outline;
    final textColor = available ? AppPalette.primary : AppPalette.comingSoon;

    // 第八轮：仅可练习小节才挂回顾入口；未上线小节既没法练习也没法回顾。
    final hasReview =
        available && ReviewRepository.instance.hasRecordsForSection(section.id);

    final pill = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchMin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap: () => onTap(section),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.buttonR,
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  available
                      ? (hasProgress
                          ? Icons.check_circle
                          : Icons.play_circle_outline)
                      : Icons.lock_outline,
                  size: 18,
                  color: hasProgress ? AppPalette.primaryAccent : textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  section.label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                _SectionStatusBadge(
                  available: available,
                  progress: progress,
                  sectionId: section.id,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!available) return pill;

    // 第八轮：在 pill 旁加一个小入口「回顾」。
    //   * 仍没有任何回顾记录时仍可点（学生需要看到入口才会去补练），但视觉
    //     置灰 + 副文案；
    //   * 至少有一条时高亮成可点击的湖青色，并展示总条数。
    //
    // 用 Row 而不是 Stack：触控热区分离，回顾按钮不会被 pill 的 InkWell
    // 误吸走点击；同时 pill 自身仍然占满主行宽度便于学生主操作。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill,
        const SizedBox(width: 6),
        _SectionReviewButton(
          section: section,
          hasReview: hasReview,
          onReview: onReview,
        ),
      ],
    );
  }
}

/// 小节 pill 旁的「回顾」入口。
///
/// 第八轮新增。
///   * 没有任何回顾记录时显示「回顾」+ 浅描边，仍可点（学生只是看到空状态）；
///   * 至少一条时附带数量 chip，文字变 primaryAccent，告诉学生有内容可看。
class _SectionReviewButton extends StatelessWidget {
  const _SectionReviewButton({
    required this.section,
    required this.hasReview,
    required this.onReview,
  });

  final CurriculumSection section;
  final bool hasReview;
  final ValueChanged<CurriculumSection> onReview;

  @override
  Widget build(BuildContext context) {
    final color =
        hasReview ? AppPalette.primaryAccent : AppPalette.textSecondary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchMin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.buttonR,
          onTap: () => onReview(section),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: hasReview ? 0.10 : 0.05),
              borderRadius: AppRadius.buttonR,
              border: Border.all(
                color: color.withValues(alpha: hasReview ? 0.4 : 0.22),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_edu_outlined, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  '回顾',
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 小节 pill 右侧的状态徽标：
///   * 未上线 → `即将上线`（保持灰色 + 锁形，**不**显示题量，避免对未上线
///     章节误标 —— 见 ROUND7 brief 第 9 节）
///   * 可练习且无完成记录 → `M 道题 · 可练习`（M 来自 [MockLectureRepository]，
///     题库为空时回退到「可练习」单段文案）
///   * 可练习且至少完成一轮 → `已完成 N 轮 · X/100`
///
/// 第六轮新增；第七轮加上「未完成时附带本节题量」。
class _SectionStatusBadge extends StatelessWidget {
  const _SectionStatusBadge({
    required this.available,
    required this.progress,
    required this.sectionId,
  });

  final bool available;
  final SectionProgress? progress;
  final String sectionId;

  @override
  Widget build(BuildContext context) {
    if (!available) {
      return _badge(color: AppPalette.comingSoon, bgAlpha: 0.18, text: '整理中');
    }
    final p = progress;
    if (p == null || !p.hasAnyCompletion) {
      // 第七轮：未完成态显示题量。题库为空（理论上不会发生，但防御未来
      // 题库被误清空）时优雅退回「可练习」单段文案，不让用户看到 `0 道题`。
      final count = MockLectureRepository.instance.questionCountForSection(
        sectionId,
      );
      final text = count > 0 ? '$count 道题 · 可练习' : '可练习';
      return _badge(color: AppPalette.primaryAccent, bgAlpha: 0.15, text: text);
    }
    return _badge(
      color: AppPalette.primaryAccent,
      bgAlpha: 0.18,
      text: '已完成 ${p.completedRounds} 轮 · ${p.masteryScore}/100',
    );
  }

  Widget _badge({
    required Color color,
    required double bgAlpha,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PendingAssignmentsBanner extends StatelessWidget {
  const _PendingAssignmentsBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppPalette.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.assignment, color: AppPalette.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('家长布置了 $count 项作业', style: Theme.of(context).textTheme.titleSmall),
                    Text('点这里查看截止时间与题面', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppPalette.primary),
            ],
          ),
        ),
      ),
    );
  }
}
