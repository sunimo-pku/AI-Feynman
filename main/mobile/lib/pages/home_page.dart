import 'package:flutter/material.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../data/mock_lecture_repository.dart';
import '../data/progress_models.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/learning_sync_service.dart';
import '../services/progress_repository.dart';
import '../services/review_repository.dart';
import '../theme/app_theme.dart';
import 'auth_page.dart';
import 'lecture_page.dart';
import 'parent_dashboard_page.dart';
import 'privacy_notice_page.dart';
import 'review_page.dart';
import 'v2_pages.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Future<MathCurriculum> _curriculumFuture =
      CurriculumRepository.instance.load();
  bool? _apiHealthy;

  @override
  void initState() {
    super.initState();
    _checkApi();
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
      }
    });
  }

  Future<void> _checkApi() async {
    final ok = await ApiService().checkHealth();
    if (mounted) setState(() => _apiHealthy = ok);
  }

  Future<void> _onSectionTap(CurriculumSection section) async {
    final hasQuestion =
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    if (section.isAvailable || hasQuestion) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LecturePage(section: section),
        ),
      );
      // 第六轮：从讲题页返回后强制 setState 触发首页重建。
      // 仓库在 completed 时已经 notifyListeners，AnimatedBuilder 会自动
      // 刷新进度徽标；这里多做一次 setState 是为了万一返回路径里 progress
      // 还没写盘完成（异步），下一帧仍能拿到最新缓存。
      if (mounted) setState(() {});
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('该章节内容制作中，请先体验「八年级下册 · 第十六章 二次根式」。'),
      ),
    );
  }

  /// 第十轮：右上角「家长端」入口。
  ///
  /// - 未登录 → 先跳 AuthPage；登录成功后再跳家长端；
  /// - 已登录 → 直接打开家长端 dashboard。
  Future<void> _onParentEntryTap(BuildContext context) async {
    final navigator = Navigator.of(context);
    await AuthService.instance.load();
    if (!mounted) return;
    if (!AuthService.instance.isLoggedIn) {
      final ok = await navigator.push<bool>(
        MaterialPageRoute(builder: (_) => const AuthPage()),
      );
      if (!mounted) return;
      if (ok != true) return;
    }
    if (!mounted) return;
    await navigator.push(
      MaterialPageRoute(builder: (_) => const ParentDashboardPage()),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 第八轮：从首页进入指定小节的讲题回顾页。
  ///
  /// 只对 `available` 的小节开放（未上线小节既没法练习也没法回顾，避免
  /// 在置灰 pill 旁边放一个能点进去的「回顾」按钮造成迷惑）。
  Future<void> _onSectionReview(CurriculumSection section) async {
    if (!section.isAvailable &&
        MockLectureRepository.instance.questionCountForSection(section.id) <= 0) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReviewPage(section: section)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(
        title: const Text('AI 费曼 · 初中数学自习室'),
        actions: [
          AnimatedBuilder(
            animation: AuthService.instance,
            builder: (_, __) {
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Center(
                  child: _ParentEntryButton(
                    onTap: () => _onParentEntryTap(context),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '隐私说明',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PrivacyNoticePage()),
            ),
            icon: const Icon(Icons.privacy_tip_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _ApiStatusBadge(healthy: _apiHealthy)),
          ),
        ],
      ),
      body: SafeArea(
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
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.pageEdge),
              children: [
                _HeroBanner(curriculum: curriculum),
                const SizedBox(height: AppSpacing.moduleGap),
                const _V2EntrySection(),
                const SizedBox(height: AppSpacing.moduleGap),
                ...curriculum.books.map(
                  (book) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
                    child: _BookCard(
                      book: book,
                      onSectionTap: _onSectionTap,
                      onSectionReview: _onSectionReview,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({required this.curriculum});

  final MathCurriculum curriculum;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 22,
                decoration: BoxDecoration(
                  color: AppPalette.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${curriculum.publisher} · ${curriculum.stageLabel}${curriculum.subjectLabel}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '第十二轮已开放 V2 演示闭环：完整目录可练习，二次根式内容精讲，悬赏、商城、排行榜与拍照识题都可从首页进入。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Tag(label: '今日开放：二次根式', color: AppPalette.primary, filled: true),
              _Tag(label: '16.1 二次根式', color: AppPalette.primaryAccent),
              _Tag(label: '16.2 乘除', color: AppPalette.primaryAccent),
              _Tag(label: '16.3 加减', color: AppPalette.primaryAccent),
            ],
          ),
        ],
      ),
    );
  }
}

class _V2EntrySection extends StatelessWidget {
  const _V2EntrySection();

  @override
  Widget build(BuildContext context) {
    final entries = <_V2Entry>[
      _V2Entry('今日悬赏', Icons.where_to_vote_outlined, () => const BountyPage()),
      _V2Entry('晶石商城', Icons.diamond_outlined, () => const ShopPage()),
      _V2Entry('排行榜', Icons.emoji_events_outlined, () => const LeaderboardPage()),
      _V2Entry('拍照识题', Icons.document_scanner_outlined, () => const PhotoQuestionPage()),
      _V2Entry('我的战力', Icons.bolt_outlined, () => const PowerProfilePage()),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('V2 产品入口', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: entries
                .map(
                  (e) => SizedBox(
                    width: 150,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => e.builder()),
                      ),
                      icon: Icon(e.icon, size: 18),
                      label: Text(e.label),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _V2Entry {
  const _V2Entry(this.label, this.icon, this.builder);
  final String label;
  final IconData icon;
  final Widget Function() builder;
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    this.filled = false,
  });

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

/// 第十轮：首页 AppBar 上的「家长端」入口。
///
/// 设计：
///   * 已登录 → 显示「家长端 · 用户名」；点击直接进入 dashboard；
///   * 未登录 → 显示「家长端 · 未登录」；点击触发登录跳转；
///   * 视觉风格与 `_ApiStatusBadge` 一致，整张 AppBar 不引入电竞色。
class _ParentEntryButton extends StatelessWidget {
  const _ParentEntryButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loggedIn = AuthService.instance.isLoggedIn;
    final username = AuthService.instance.currentUsername;
    final color = loggedIn ? AppPalette.primary : AppPalette.textSecondary;
    final label = loggedIn ? '家长端 · $username' : '家长端';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.family_restroom_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApiStatusBadge extends StatelessWidget {
  const _ApiStatusBadge({required this.healthy});

  final bool? healthy;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (healthy) {
      true => ('API 已连接', AppPalette.primaryAccent),
      false => ('API 未连接', AppPalette.error),
      null => ('检测中…', AppPalette.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
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
    final hasAvailable = book.chapters.any((c) => c.sections.any((s) =>
        s.isAvailable ||
        MockLectureRepository.instance.questionCountForSection(s.id) > 0));
    return Card(
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
              hasAvailable
                  ? 'V1 已开放章节'
                  : '即将上线',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: hasAvailable
                        ? AppPalette.primaryAccent
                        : AppPalette.comingSoon,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          children: book.chapters.map((chapter) {
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
    final chapterAvailable = chapter.sections.any((s) =>
        s.isAvailable ||
        MockLectureRepository.instance.questionCountForSection(s.id) > 0);
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
                      color: chapterAvailable
                          ? AppPalette.textPrimary
                          : AppPalette.comingSoon,
                    ),
              ),
              if (!chapterAvailable) ...[
                const SizedBox(width: 8),
                const Icon(Icons.lock_outline,
                    size: 14, color: AppPalette.comingSoon),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chapter.sections
                .map((s) => _SectionPill(
                      section: s,
                      onTap: onSectionTap,
                      onReview: onSectionReview,
                    ))
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
    final available = section.isAvailable ||
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
        final progress =
            ProgressRepository.instance.progressFor(section.id);
        return _buildPill(context, progress: progress);
      },
    );
  }

  Widget _buildPill(BuildContext context, {required SectionProgress? progress}) {
    final available = section.isAvailable ||
        MockLectureRepository.instance.questionCountForSection(section.id) > 0;
    final hasProgress = progress != null && progress.hasAnyCompletion;
    final bg = available
        ? AppPalette.primary.withValues(alpha: 0.08)
        : AppPalette.comingSoon.withValues(alpha: 0.08);
    final border = available
        ? AppPalette.primary.withValues(alpha: 0.4)
        : AppPalette.outline;
    final textColor = available ? AppPalette.primary : AppPalette.comingSoon;

    // 第八轮：仅可练习小节才挂回顾入口；未上线小节既没法练习也没法回顾。
    final hasReview = available &&
        ReviewRepository.instance.hasRecordsForSection(section.id);

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
                  color: hasProgress
                      ? AppPalette.primaryAccent
                      : textColor,
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
      return _badge(
        color: AppPalette.comingSoon,
        bgAlpha: 0.18,
        text: '即将上线',
      );
    }
    final p = progress;
    if (p == null || !p.hasAnyCompletion) {
      // 第七轮：未完成态显示题量。题库为空（理论上不会发生，但防御未来
      // 题库被误清空）时优雅退回「可练习」单段文案，不让用户看到 `0 道题`。
      final count = MockLectureRepository.instance
          .questionCountForSection(sectionId);
      final text = count > 0 ? '$count 道题 · 可练习' : '可练习';
      return _badge(
        color: AppPalette.primaryAccent,
        bgAlpha: 0.15,
        text: text,
      );
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
