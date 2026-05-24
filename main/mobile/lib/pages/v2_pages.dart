import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/curriculum_models.dart';
import '../data/curriculum_repository.dart';
import '../data/learning_profile_models.dart';
import '../data/lecture_models.dart';
import '../data/mock_lecture_repository.dart';
import '../data/round12_models.dart';
import '../services/auth_service.dart';
import '../services/round12_service.dart';
import '../services/student_grade_store.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/learning_profile_panel.dart';
import '../widgets/study_layout.dart';
import 'lecture_page.dart';
import 'privacy_notice_page.dart';
import 'favorite_questions_page.dart';

const List<String> _gradeOptions = <String>['七年级', '八年级', '九年级'];

class PowerProfilePage extends StatefulWidget {
  const PowerProfilePage({
    super.key,
    this.embeddedInTab = false,
    this.onProfileSaved,
  });

  /// 嵌入学生端底部「我的」Tab 时不重复套 AppBar。
  final bool embeddedInTab;

  /// 资料保存后通知主壳刷新年级（全局唯一修改入口）。
  final Future<void> Function()? onProfileSaved;

  @override
  State<PowerProfilePage> createState() => _PowerProfilePageState();
}

class _PowerProfilePageState extends State<PowerProfilePage> {
  final _service = Round12Service();
  late Future<PowerProfile> _future = _service.fetchPowerProfile();
  late final Future<LearningProfilePayload> _learningProfileFuture =
      _service.fetchLearningProfile();
  Map<String, String> _chapterLabels = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadChapterLabels());
  }

  Future<void> _loadChapterLabels() async {
    final map = await CurriculumRepository.instance.chapterLabelIndex();
    if (!mounted) return;
    setState(() => _chapterLabels = map);
  }

  String _chapterTitle(PowerChapter chapter) {
    return _chapterLabels[chapter.chapterId] ?? chapter.chapterId;
  }

  List<PowerChapter> _chaptersForGrade(PowerProfile profile) {
    final grade = StudentGradeStore.instance.gradeLabel;
    if (grade == null) return profile.chapters;
    return profile.chapters
        .where((c) => chapterMatchesGrade(c.chapterId, grade))
        .toList(growable: false);
  }

  String _rankTierForTotal(int score) {
    if (score >= 900) return '王者';
    if (score >= 600) return '黄金';
    if (score >= 300) return '白银';
    return '青铜';
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = AnimatedBuilder(
      animation: StudentGradeStore.instance,
      builder: (context, _) {
        return FutureBuilder<PowerProfile>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return _loadingOrError(
                snapshot,
                () => setState(() => _future = _service.fetchPowerProfile()),
              );
            }
            final p = snapshot.data!;
            final grade = StudentGradeStore.instance.gradeLabel;
            final chapters = _chaptersForGrade(p);
            final total = chapters.fold<int>(0, (sum, c) => sum + c.powerScore);
            return ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.pageEdge,
                widget.embeddedInTab ? 12 : AppSpacing.pageEdge,
                AppSpacing.pageEdge,
                24,
              ),
              children: [
                if (widget.embeddedInTab) ...[
                  Text(
                    '我的成长',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                StudyPanel(
                  tone: StudyPanelTone.primary,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StudyDenseTile(
                        title: p.studentName,
                        subtitle: _rankTierForTotal(total),
                        icon: Icons.bolt_outlined,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          StudyStatPill(
                            label: grade == null ? '总战力' : '$grade总战力',
                            value: '$total',
                            icon: Icons.trending_up,
                          ),
                          StudyStatPill(
                            label: '晶石',
                            value: '${p.crystalBalance}',
                            icon: Icons.diamond_outlined,
                            accent: AppPalette.primaryAccent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _LearningProfilePreview(future: _learningProfileFuture),
                const SizedBox(height: 20),
                StudySectionTitle(
                  title: grade == null ? '章节战力' : '$grade · 章节战力',
                ),
                if (chapters.isEmpty)
                  StudyEmptyHint(
                    grade == null
                        ? '完成一轮讲题或今日悬赏后，这里会出现各章战力。'
                        : '完成$grade讲题或每日挑战后，这里会出现各章战力。',
                  )
                else
                  StudyGroupedPanel(
                    children:
                        chapters
                            .map(
                              (c) => StudyDenseTile(
                                title: _chapterTitle(c),
                                subtitle: '${c.rankTier} · ${c.powerScore} 战力',
                                icon: Icons.insights_outlined,
                                dense: true,
                              ),
                            )
                            .toList(),
                  ),
                const SizedBox(height: 20),
                const StudySectionTitle(title: '我的收藏'),
                StudyGroupedPanel(
                  children: [
                    StudyListRow(
                      title: '收藏的题目',
                      subtitle: '讲题页点星星收藏，方便回头再练',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const FavoriteQuestionsPage(),
                            ),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const StudySectionTitle(title: '资料与隐私'),
                StudyGroupedPanel(
                  children: [
                    StudyListRow(
                      title: '我的资料',
                      subtitle: '年级、昵称与学校地区',
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const StudentProfileEditPage(),
                          ),
                        );
                        await widget.onProfileSaved?.call();
                      },
                    ),
                    StudyListRow(
                      title: '隐私说明',
                      subtitle: '数据收集、权限与麦克风使用',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PrivacyNoticePage(),
                            ),
                          ),
                    ),
                  ],
                ),
                if (widget.embeddedInTab) ...[
                  const SizedBox(height: 20),
                  const StudySectionTitle(title: '账号'),
                  AnimatedBuilder(
                    animation: AuthService.instance,
                    builder: (context, _) {
                      final username = AuthService.instance.currentUsername;
                      return StudyGroupedPanel(
                        children: [
                          StudyDenseTile(
                            title: username.isEmpty ? '当前账号' : username,
                            subtitle: '学生端',
                            icon: Icons.person_outline,
                            showIconBox: true,
                          ),
                          StudyListRow(
                            title: '切换到家长账号',
                            subtitle: '查看学习报告与作业',
                            onTap: () => _showSwitchParentDialog(context),
                          ),
                          StudyListRow(
                            title: '退出账号',
                            subtitle: '退出后需重新登录',
                            onTap: () => unawaited(_logoutAccount()),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    );
    if (widget.embeddedInTab) {
      return body;
    }
    return _ScaffoldShell(title: '我的战力', child: body);
  }
}

class _LearningProfilePreview extends StatelessWidget {
  const _LearningProfilePreview({required this.future});

  final Future<LearningProfilePayload> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LearningProfilePayload>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return LearningProfilePanel(profile: snapshot.data!, compact: true);
        }
        if (snapshot.hasError) {
          return const StudyInlineBanner(
            message: '学习画像暂时加载失败，完成讲题后可以稍后再看。',
            icon: Icons.info_outline,
          );
        }
        return const StudyPanel(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: StudyDenseTile(
            title: '长期学习画像',
            subtitle: '正在读取讲题记录与错因证据…',
            icon: Icons.psychology_alt_outlined,
            accent: AppPalette.primaryAccent,
          ),
        );
      },
    );
  }
}

Future<void> _logoutAccount() async {
  await AuthService.instance.logout();
}

Future<void> _showSwitchParentDialog(BuildContext context) async {
  if (!AuthService.instance.isStudent) return;

  final parentPasswordController = TextEditingController();
  var submitting = false;
  String? errorMessage;
  var shouldNotifySessionChanged = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> submit() async {
            final parentPassword = parentPasswordController.text;
            if (parentPassword.length < 6) {
              setDialogState(() => errorMessage = '请填写家长密码（至少 6 位）。');
              return;
            }
            setDialogState(() {
              submitting = true;
              errorMessage = null;
            });
            final result = await AuthService.instance.switchToParent(
              parentPassword: parentPassword,
              notify: false,
            );
            if (!ctx.mounted) return;
            if (!result.ok) {
              setDialogState(() {
                submitting = false;
                errorMessage = result.message;
              });
              return;
            }
            shouldNotifySessionChanged = true;
            Navigator.of(ctx).pop();
          }

          return AlertDialog(
            title: const Text('切换到家长账号'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '当前已登录学生端，输入家长密码即可进入家长端查看报告。',
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: parentPasswordController,
                    obscureText: true,
                    enabled: !submitting,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '家长密码',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(submit()),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorMessage!,
                      style: Theme.of(
                        ctx,
                      ).textTheme.bodySmall?.copyWith(color: AppPalette.error),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting ? null : () => unawaited(submit()),
                child:
                    submitting
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text('进入家长端'),
              ),
            ],
          );
        },
      );
    },
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    parentPasswordController.dispose();
  });
  if (shouldNotifySessionChanged) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AuthService.instance.notifySessionChanged();
    });
  }
}

class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key, this.embeddedInTab = false});

  /// 嵌入学生端底部「排行榜」Tab 时不重复套 AppBar。
  final bool embeddedInTab;

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _service = Round12Service();
  String _scope = 'school';
  String _chapterId = 'pep-g8-down-ch16';
  Map<String, String> _chapterLabels = const {};
  List<PowerChapter> _rankedChapters = const [];
  Future<List<LeaderboardEntry>>? _entriesFuture;
  bool _bootstrapping = true;
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final labels = await CurriculumRepository.instance.chapterLabelIndex();
      final profile = await _service.fetchPowerProfile();
      final grade = StudentGradeStore.instance.gradeLabel;
      var chapters = profile.chapters;
      if (grade != null) {
        chapters = chapters
            .where((c) => chapterMatchesGrade(c.chapterId, grade))
            .toList(growable: false);
      }
      final ranked = [...chapters]
        ..sort((a, b) => b.powerScore.compareTo(a.powerScore));
      final withPower = ranked.where((c) => c.powerScore > 0).toList();
      var chapterId = _chapterId;
      if (withPower.isNotEmpty) {
        chapterId = withPower.first.chapterId;
      } else if (ranked.isNotEmpty) {
        chapterId = ranked.first.chapterId;
      } else if (grade != null) {
        chapterId = labels.keys.firstWhere(
          (id) => chapterMatchesGrade(id, grade),
          orElse: () => _chapterId,
        );
      }
      if (!mounted) return;
      setState(() {
        _chapterLabels = labels;
        _rankedChapters = withPower.isNotEmpty ? withPower : ranked;
        _chapterId = chapterId;
        _bootstrapping = false;
        _bootstrapError = null;
        _entriesFuture = _loadEntries();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bootstrapping = false;
        _bootstrapError = '$e';
        _entriesFuture = _loadEntries();
      });
    }
  }

  Future<List<LeaderboardEntry>> _loadEntries() {
    return _service.fetchLeaderboard(scope: _scope, chapterId: _chapterId);
  }

  void _reloadEntries() {
    setState(() => _entriesFuture = _loadEntries());
  }

  void _selectScope(String scope) {
    setState(() {
      _scope = scope;
      _entriesFuture = _loadEntries();
    });
  }

  void _selectChapter(String chapterId) {
    setState(() {
      _chapterId = chapterId;
      _entriesFuture = _loadEntries();
    });
  }

  String get _chapterTitle => _chapterLabels[_chapterId] ?? _chapterId;

  bool get _canSwitchChapter => _rankedChapters.length > 1;

  @override
  Widget build(BuildContext context) {
    const labels = {
      'school': '校榜',
      'district': '区榜',
      'city': '市榜',
      'province': '省榜',
    };
    final theme = Theme.of(context);
    final body = ListView(
      padding: const EdgeInsets.all(AppSpacing.pageEdge),
      children: [
        Wrap(
          spacing: 8,
          children:
              labels.entries
                  .map(
                    (e) => ChoiceChip(
                      label: Text(e.value),
                      selected: _scope == e.key,
                      onSelected: (_) => _selectScope(e.key),
                    ),
                  )
                  .toList(),
        ),
        const SizedBox(height: 10),
        Text(
          '排名章节：$_chapterTitle',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: AppPalette.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _canSwitchChapter
              ? '排行榜按大章分别计算。默认展示你战力最高的一章，也可以在下方切换到其它已有战力的章节。'
              : '排行榜按大章分别计算。当前展示你已有战力的章节；各小节战力会汇总到对应大章。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.4,
          ),
        ),
        if (_canSwitchChapter) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                _rankedChapters
                    .map(
                      (c) => ChoiceChip(
                        label: Text(_chapterLabels[c.chapterId] ?? c.chapterId),
                        selected: _chapterId == c.chapterId,
                        onSelected: (_) => _selectChapter(c.chapterId),
                      ),
                    )
                    .toList(),
          ),
        ],
        const SizedBox(height: 12),
        if (_bootstrapping)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_bootstrapError != null)
          StudyEmptyHint('加载章节战力失败：$_bootstrapError')
        else
          FutureBuilder<List<LeaderboardEntry>>(
            future: _entriesFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return _loadingOrError(snapshot, _reloadEntries);
              }
              final entries = snapshot.data!;
              if (entries.isEmpty) {
                final hint =
                    _canSwitchChapter
                        ? '「$_chapterTitle」在${labels[_scope] ?? _scope}还没有记录。可以切换到其它章节查看，或完成该章讲题 / 每日挑战后再刷新。'
                        : '「$_chapterTitle」在${labels[_scope] ?? _scope}还没有记录。完成该章节的讲题或每日挑战后，会在这里出现你的名次。';
                return StudyEmptyHint(hint);
              }
              return StudyGroupedPanel(
                children:
                    entries
                        .map(
                          (e) => StudyDenseTile(
                            dense: true,
                            title: e.studentName,
                            subtitle: e.titleLabel,
                            icon: Icons.emoji_events_outlined,
                            accent:
                                e.rank <= 3
                                    ? AppPalette.primaryAccent
                                    : AppPalette.primary,
                            trailing: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '#${e.rank}',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.primary,
                                  ),
                                ),
                                Text(
                                  '${e.powerScore}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
              );
            },
          ),
      ],
    );
    if (widget.embeddedInTab) {
      return body;
    }
    return _ScaffoldShell(title: '排行榜', child: body);
  }
}

class BountyPage extends StatefulWidget {
  const BountyPage({super.key});

  @override
  State<BountyPage> createState() => _BountyPageState();
}

class _BountyPageState extends State<BountyPage> {
  final _service = Round12Service();
  final _transcript = TextEditingController();
  late Future<List<BountyChallenge>> _future = _service.fetchBounties();
  String _message = '';

  @override
  void dispose() {
    _transcript.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _submit(BountyChallenge c) async {
    final quizzes = c.stepQuizzes;
    if (quizzes.isEmpty) {
      if (!mounted) return;
      setState(() => _message = '本题缺少分步题，请从首页「每日挑战」进入。');
      return;
    }
    final stepAnswers = quizzes
        .map((q) => {'stepId': q.stepId, 'optionId': q.correctOptionId})
        .toList(growable: false);
    final result = await _service.submitBounty(
      challengeId: c.challengeId,
      stepAnswers: stepAnswers,
      transcriptText: _transcript.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _message =
          result.completed
              ? '挑战完成，获得 ${result.crystalReward} 晶石 / ${result.powerReward} 战力。'
              : '还差一点：分步选择与讲解都要过关。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '今日悬赏',
      child: FutureBuilder<List<BountyChallenge>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _loadingOrError(
              snapshot,
              () => setState(() => _future = _service.fetchBounties()),
            );
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(child: StudyEmptyHint('今天暂时没有悬赏题。'));
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              if (_message.isNotEmpty)
                StudyInlineBanner(
                  message: _message,
                  tone: StudyPanelTone.accent,
                  icon: Icons.check_circle_outline,
                ),
              ...items.map(
                (c) => _BountyCard(
                  challenge: c,
                  transcript: _transcript,
                  onSubmit: () => _submit(c),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  final _service = Round12Service();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  late Future<ShopCatalog> _future = _service.fetchShopCatalog();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _redeem(ShopItem item) async {
    final shipName = _name.text.trim();
    final shipPhone = _phone.text.trim();
    final shipAddress = _address.text.trim();
    if (shipName.isEmpty || shipPhone.isEmpty || shipAddress.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写收货人、电话和详细地址')));
      return;
    }
    await _service.redeem(
      item.skuId,
      address: {'name': shipName, 'phone': shipPhone, 'address': shipAddress},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${item.name} 兑换已提交，等待发货（占位奖品）')));
    setState(() => _future = _service.fetchShopCatalog());
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '晶石商城',
      child: FutureBuilder<ShopCatalog>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _loadingOrError(
              snapshot,
              () => setState(() => _future = _service.fetchShopCatalog()),
            );
          }
          final catalog = snapshot.data!;
          final stationery = catalog.items;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  StudyStatPill(
                    label: '晶石余额',
                    value: '${catalog.balance} 颗',
                    icon: Icons.diamond_outlined,
                  ),
                  const StudyStatPill(
                    label: '兑换说明',
                    value: '实物占位',
                    icon: Icons.inventory_2_outlined,
                    accent: AppPalette.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const StudySectionTitle(
                title: '收货信息',
                subtitle: '兑换实物前请填写完整收货信息',
              ),
              StudyPanel(
                tone: StudyPanelTone.quiet,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Column(
                  children: [
                    _TextField(controller: _name, label: '收货人'),
                    _TextField(controller: _phone, label: '电话'),
                    _TextField(controller: _address, label: '详细地址'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const StudySectionTitle(title: '文具兑换'),
              if (stationery.isEmpty)
                const StudyEmptyHint('暂无文具商品，稍后再来看看。')
              else
                StudyGroupedPanel(
                  children:
                      stationery
                          .map(
                            (item) => _shopDenseTile(
                              context,
                              item,
                              () => _redeem(item),
                            ),
                          )
                          .toList(),
                ),
              const SizedBox(height: 14),
              const StudySectionTitle(title: '我的订单'),
              FutureBuilder<Map<String, dynamic>>(
                future: _service.fetchOrders(),
                builder: (context, orders) {
                  final raw = orders.data?['orders'];
                  final rows = raw is List ? raw : const [];
                  if (rows.isEmpty) {
                    return const StudyEmptyHint('暂无兑换订单');
                  }
                  return StudyGroupedPanel(
                    children:
                        rows
                            .map(
                              (e) => StudyDenseTile(
                                dense: true,
                                title: '${e['skuId']}',
                                subtitle: '${e['status']}',
                                icon: Icons.local_shipping_outlined,
                              ),
                            )
                            .toList(),
                  );
                },
              ),
              const SizedBox(height: 14),
              const StudySectionTitle(title: '最近流水'),
              FutureBuilder<Map<String, dynamic>>(
                future: _service.fetchLedger(),
                builder: (context, ledger) {
                  final raw = ledger.data?['ledger'];
                  final rows = raw is List ? raw.take(5).toList() : const [];
                  if (rows.isEmpty) {
                    return const StudyEmptyHint('暂无晶石流水');
                  }
                  return StudyGroupedPanel(
                    children:
                        rows
                            .map(
                              (e) => StudyDenseTile(
                                dense: true,
                                title: '${e['reason']}',
                                subtitle: '${e['amount']}',
                                icon: Icons.receipt_long_outlined,
                              ),
                            )
                            .toList(),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class PhotoQuestionPage extends StatefulWidget {
  const PhotoQuestionPage({super.key});

  @override
  State<PhotoQuestionPage> createState() => _PhotoQuestionPageState();
}

class _PhotoQuestionPageState extends State<PhotoQuestionPage> {
  final _service = Round12Service();
  final _picker = ImagePicker();
  Map<String, dynamic>? _result;
  String? _error;
  bool _uploading = false;

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _pickFrom(ImageSource source) async {
    if (_uploading) return;
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 88,
      maxWidth: 2048,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final result = await _service.uploadQuestionImage(File(picked.path));
      if (!mounted) return;
      setState(() {
        _result = result;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _startLecture() async {
    final result = _result;
    final prompt = (result?['questionPrompt'] as String? ?? '').trim();
    if (result == null || prompt.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('还没有识别到题面，请重新拍照或从相册选择。')));
      return;
    }
    await MockLectureRepository.instance.loadAssetBank();
    if (!mounted) return;
    final grade =
        StudentGradeStore.instance.gradeLabel ?? StudentGradeStore.defaultGrade;
    final rawSectionId = (result['sectionId'] as String? ?? '').trim();
    final sectionId =
        sectionMatchesGrade(rawSectionId, grade)
            ? rawSectionId
            : _defaultSectionIdForGrade(grade);
    if (sectionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂时无法匹配到当前年级的小节，请先到课程页选题讲解。')),
      );
      return;
    }
    final section = CurriculumSection(
      id: sectionId,
      number: '识题',
      title: '拍照识题推荐',
      label: '拍照识题推荐章节',
      type: 'lesson',
      contentStatus: 'available',
      v1Launch: true,
      practiceAvailable: true,
    );
    final question = LectureQuestion(
      questionId: 'q-photo-${DateTime.now().millisecondsSinceEpoch}',
      sectionId: sectionId,
      sectionLabel: section.label,
      prompt: prompt,
      hint: '请按你拍到的题面，讲清已知条件、关键步骤和容易出错的地方。',
      referenceSteps: const [],
      tags: const ['拍照识题'],
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => LecturePage(section: section, questionOverride: question),
      ),
    );
  }

  String? _defaultSectionIdForGrade(String grade) {
    switch (grade.trim()) {
      case '七年级':
        return 'pep-g7-up-s1-1';
      case '八年级':
        return 'pep-g8-down-s16-1';
      case '九年级':
        return 'pep-g9-up-s21-1';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return _ScaffoldShell(
      title: '拍照识题',
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          Text(
            '拍一张题目或从相册选图，识别后可直接进入讲题。',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      _uploading ? null : () => _pickFrom(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('拍照'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _uploading ? null : () => _pickFrom(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('相册'),
                ),
              ),
            ],
          ),
          if (_uploading) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '正在识别题目…',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
          ],
          if (_error != null)
            StudyInlineBanner(
              message: _error!,
              tone: StudyPanelTone.danger,
              icon: Icons.error_outline,
            ),
          if (r != null) ...[
            const SizedBox(height: 12),
            StudyPanel(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StudyDenseTile(
                    title: '推荐章节 ${r['sectionId']}',
                    subtitle: '置信度 ${r['confidence']} · ${r['source']}',
                    icon: Icons.document_scanner_outlined,
                  ),
                  const SizedBox(height: 8),
                  FormulaText(
                    r['questionPrompt'] as String? ?? '',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _startLecture, child: const Text('进入讲题')),
          ],
        ],
      ),
    );
  }
}

class StudentProfileEditPage extends StatefulWidget {
  const StudentProfileEditPage({super.key});

  @override
  State<StudentProfileEditPage> createState() => _StudentProfileEditPageState();
}

class _StudentProfileEditPageState extends State<StudentProfileEditPage> {
  final _service = Round12Service();
  final _display = TextEditingController();
  final _grade = TextEditingController();
  final _school = TextEditingController();
  final _province = TextEditingController();
  final _city = TextEditingController();
  final _district = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _service.fetchProfile();
    if (!mounted) return;
    _display.text = p['displayName'] as String? ?? '';
    _grade.text = p['grade'] as String? ?? '';
    _school.text = p['schoolName'] as String? ?? '';
    _province.text = p['province'] as String? ?? '';
    _city.text = p['city'] as String? ?? '';
    _district.text = p['district'] as String? ?? '';
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final grade = _grade.text.trim();
    await _service.updateProfile({
      'displayName': _display.text.trim(),
      'grade': grade,
      'schoolName': _school.text.trim(),
      'province': _province.text.trim(),
      'city': _city.text.trim(),
      'district': _district.text.trim(),
    });
    if (StudentGradeStore.validGrades.contains(grade)) {
      await StudentGradeStore.instance.setGrade(grade);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('资料已保存，年级已同步到今日与课程')));
  }

  @override
  void dispose() {
    for (final c in [_display, _grade, _school, _province, _city, _district]) {
      c.dispose();
    }
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '学生资料',
      child:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.all(AppSpacing.pageEdge),
                children: [
                  _TextField(controller: _display, label: '展示名'),
                  DropdownButtonFormField<String>(
                    initialValue:
                        _gradeOptions.contains(_grade.text)
                            ? _grade.text
                            : '八年级',
                    decoration: const InputDecoration(labelText: '年级'),
                    items:
                        _gradeOptions
                            .map(
                              (grade) => DropdownMenuItem(
                                value: grade,
                                child: Text(grade),
                              ),
                            )
                            .toList(),
                    onChanged: (value) => _grade.text = value ?? _grade.text,
                  ),
                  const SizedBox(height: 10),
                  _TextField(controller: _school, label: '学校'),
                  _TextField(controller: _province, label: '省'),
                  _TextField(controller: _city, label: '市'),
                  _TextField(controller: _district, label: '区/县'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _save, child: const Text('保存')),
                ],
              ),
    );
  }
}

StudyDenseTile _shopDenseTile(
  BuildContext context,
  ShopItem item,
  VoidCallback onRedeem,
) {
  final desc =
      item.description.trim().isEmpty ? '占位文具' : item.description.trim();
  return StudyDenseTile(
    title: item.name,
    subtitle: desc,
    icon: Icons.inventory_2_outlined,
    trailing: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${item.crystalCost}',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: AppPalette.primaryAccent,
          ),
        ),
        const SizedBox(height: 4),
        FilledButton.tonal(
          onPressed: onRedeem,
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('兑换'),
        ),
      ],
    ),
  );
}

class _ScaffoldShell extends StatelessWidget {
  const _ScaffoldShell({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StudyShell(title: title, maxWidth: 980, child: child);
  }
}

Widget _loadingOrError(AsyncSnapshot snapshot, VoidCallback retry) {
  if (snapshot.hasError) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：${snapshot.error}', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
  return const Center(child: CircularProgressIndicator());
}

class _BountyCard extends StatelessWidget {
  const _BountyCard({
    required this.challenge,
    required this.transcript,
    required this.onSubmit,
  });

  final BountyChallenge challenge;
  final TextEditingController transcript;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FormulaText(
            challenge.prompt,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          FormulaText('错误步骤：${challenge.wrongStep}'),
          const SizedBox(height: 8),
          TextField(
            controller: transcript,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '把你的纠错讲解写在这里'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(Icons.send_outlined),
            label: Text('提交讲解（开发页） · +${challenge.rewardCrystals} 晶石'),
          ),
        ],
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({required this.controller, required this.label});
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
