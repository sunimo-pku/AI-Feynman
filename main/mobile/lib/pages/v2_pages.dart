import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/curriculum_models.dart';
import '../data/round12_models.dart';
import '../services/auth_service.dart';
import '../services/round12_service.dart';
import '../services/student_grade_store.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import '../widgets/study_layout.dart';
import 'lecture_page.dart';

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

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder<PowerProfile>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _loadingOrError(
            snapshot,
            () => setState(() => _future = _service.fetchPowerProfile()),
          );
        }
        final p = snapshot.data!;
        final total = p.sections.fold<int>(0, (sum, s) => sum + s.powerScore);
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
                    subtitle:
                        p.equippedTitle.isEmpty
                            ? '数学练习生'
                            : p.equippedTitle,
                    icon: Icons.bolt_outlined,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StudyStatPill(
                        label: '总战力',
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
            FilledButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const StudentProfileEditPage(),
                  ),
                );
                await widget.onProfileSaved?.call();
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('编辑展示名 / 年级'),
            ),
            const SizedBox(height: 12),
            const StudySectionTitle(title: '章节战力'),
            if (p.sections.isEmpty)
              const StudyEmptyHint('完成一轮讲题或今日悬赏后，这里会出现章节战力。')
            else
              StudyGroupedPanel(
                children:
                    p.sections
                        .map(
                          (s) => StudyDenseTile(
                            title: s.sectionId,
                            subtitle: '${s.rankTier} · ${s.powerScore} 战力',
                            icon: Icons.insights_outlined,
                            dense: true,
                          ),
                        )
                        .toList(),
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
    if (widget.embeddedInTab) {
      return body;
    }
    return _ScaffoldShell(title: '我的战力', child: body);
  }
}

Future<void> _logoutAccount() async {
  await AuthService.instance.logout();
}

Future<void> _showSwitchParentDialog(BuildContext context) async {
  final username = AuthService.instance.currentUsername;
  if (username.isEmpty) return;

  final accountPasswordController = TextEditingController();
  final parentPasswordController = TextEditingController();
  var submitting = false;
  String? errorMessage;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> submit() async {
            final accountPassword = accountPasswordController.text;
            final parentPassword = parentPasswordController.text;
            if (accountPassword.length < 6) {
              setDialogState(
                () => errorMessage = '请填写账号密码（至少 6 位）。',
              );
              return;
            }
            if (parentPassword.length < 6) {
              setDialogState(
                () => errorMessage = '请填写家长密码（至少 6 位）。',
              );
              return;
            }
            setDialogState(() {
              submitting = true;
              errorMessage = null;
            });
            final result = await AuthService.instance.login(
              username: username,
              password: accountPassword,
              loginAs: 'parent',
              parentPassword: parentPassword,
            );
            if (!ctx.mounted) return;
            if (!result.ok) {
              setDialogState(() {
                submitting = false;
                errorMessage = result.message;
              });
              return;
            }
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
                    '账号：$username',
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: accountPasswordController,
                    obscureText: true,
                    enabled: !submitting,
                    decoration: const InputDecoration(
                      labelText: '账号密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: parentPasswordController,
                    obscureText: true,
                    enabled: !submitting,
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
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: AppPalette.error,
                      ),
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

  accountPasswordController.dispose();
  parentPasswordController.dispose();
}

class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key});

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _service = Round12Service();
  String _scope = 'school';
  late Future<List<LeaderboardEntry>> _future = _service.fetchLeaderboard(
    scope: _scope,
  );

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  void _select(String scope) {
    setState(() {
      _scope = scope;
      _future = _service.fetchLeaderboard(scope: scope);
    });
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      'school': '校榜',
      'district': '区榜',
      'city': '市榜',
      'province': '省榜',
    };
    return _ScaffoldShell(
      title: '排行榜',
      child: ListView(
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
                        onSelected: (_) => _select(e.key),
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<LeaderboardEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return _loadingOrError(snapshot, () => _select(_scope));
              }
              final entries = snapshot.data!;
              if (entries.isEmpty) {
                return const StudyEmptyHint('本周还没有同地区战力记录，先完成一题冲榜。');
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: AppPalette.primary,
                                      ),
                                ),
                                Text(
                                  '${e.powerScore}',
                                  style: Theme.of(context).textTheme.bodySmall,
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
      ),
    );
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
    final stepAnswers =
        quizzes
            .map(
              (q) => {'stepId': q.stepId, 'optionId': q.correctOptionId},
            )
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写收货人、电话和详细地址')),
      );
      return;
    }
    await _service.redeem(
      item.skuId,
      address: {
        'name': shipName,
        'phone': shipPhone,
        'address': shipAddress,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${item.name} 兑换已提交，等待发货（占位奖品）')),
    );
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
                  StudyStatPill(
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
                    _TextField(
                      controller: _address,
                      label: '详细地址',
                    ),
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
  Map<String, dynamic>? _result;
  String? _error;

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final result = await _service.uploadQuestionImage(File(picked.path));
      if (!mounted) return;
      setState(() {
        _result = result;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _startLecture() {
    final sectionId = _result?['sectionId'] as String? ?? 'pep-g8-down-s16-3';
    final section = CurriculumSection(
      id: sectionId,
      number: '16.x',
      title: '拍照识题推荐',
      label: '拍照识题推荐章节',
      type: 'lesson',
      contentStatus: 'available',
      v1Launch: true,
    );
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => LecturePage(section: section)));
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return _ScaffoldShell(
      title: '拍照识题',
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          FilledButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('从相册选择题目图片'),
          ),
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
      item.description.trim().isEmpty
          ? '占位文具'
          : item.description.trim();
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

