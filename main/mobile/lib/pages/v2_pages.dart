import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/curriculum_models.dart';
import '../data/round12_models.dart';
import '../services/round12_service.dart';
import '../services/user_cosmetics_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/formula_text.dart';
import 'lecture_page.dart';

class PowerProfilePage extends StatefulWidget {
  const PowerProfilePage({super.key});

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
    return _ScaffoldShell(
      title: '我的战力',
      child: FutureBuilder<PowerProfile>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _loadingOrError(snapshot, () => setState(() => _future = _service.fetchPowerProfile()));
          final p = snapshot.data!;
          final total = p.sections.fold<int>(0, (sum, s) => sum + s.powerScore);
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _InfoCard(
                title: p.studentName,
                subtitle: '总战力 $total · ${p.equippedTitle.isEmpty ? '二次根式练习生' : p.equippedTitle} · 晶石 ${p.crystalBalance}',
                icon: Icons.bolt_outlined,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StudentProfileEditPage()),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('编辑展示名 / 学校地区'),
              ),
              const SizedBox(height: 12),
              if (p.sections.isEmpty)
                const _EmptyCard('完成一轮讲题或今日悬赏后，这里会出现章节战力。')
              else
                ...p.sections.map((s) => _PowerRow(section: s)),
            ],
          );
        },
      ),
    );
  }
}

class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key});

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _service = Round12Service();
  String _scope = 'school';
  late Future<List<LeaderboardEntry>> _future = _service.fetchLeaderboard(scope: _scope);

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
            children: labels.entries
                .map((e) => ChoiceChip(
                      label: Text(e.value),
                      selected: _scope == e.key,
                      onSelected: (_) => _select(e.key),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<LeaderboardEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return _loadingOrError(snapshot, () => _select(_scope));
              final entries = snapshot.data!;
              if (entries.isEmpty) return const _EmptyCard('本周还没有同地区战力记录，先完成一题冲榜。');
              return Column(
                children: entries
                    .map((e) => _InfoCard(
                          title: '#${e.rank} ${e.studentName}',
                          subtitle: '${e.powerScore} 战力 · ${e.rankTier}\n${e.titleLabel}',
                          icon: Icons.emoji_events_outlined,
                        ))
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
    final result = await _service.submitBounty(
      challengeId: c.challengeId,
      circledBox: c.errorBox,
      transcriptText: _transcript.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _message = result['completed'] == true
          ? '挑战完成，获得 ${result['crystalReward']} 晶石 / ${result['powerReward']} 战力。'
          : '还差一点：圈选和讲解都要命中错误点。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '今日悬赏',
      child: FutureBuilder<List<BountyChallenge>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _loadingOrError(snapshot, () => setState(() => _future = _service.fetchBounties()));
          final items = snapshot.data!;
          if (items.isEmpty) return const _EmptyCard('今天暂时没有悬赏题。');
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              if (_message.isNotEmpty) _InfoCard(title: '提交结果', subtitle: _message, icon: Icons.check_circle_outline),
              ...items.map((c) => _BountyCard(
                    challenge: c,
                    transcript: _transcript,
                    onSubmit: () => _submit(c),
                  )),
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
  late Future<ShopCatalog> _future = _service.fetchShopCatalog();

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _redeem(ShopItem item) async {
    await _service.redeem(item.skuId);
    if (item.type == 'penStyle') {
      await UserCosmeticsPrefs.instance.equipPenStyle(item.skuId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已兑换 ${item.name}')),
    );
    setState(() => _future = _service.fetchShopCatalog());
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '晶石商城',
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const GeekShopPage()),
          ),
          child: const Text('工具局'),
        )
      ],
      child: FutureBuilder<ShopCatalog>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _loadingOrError(snapshot, () => setState(() => _future = _service.fetchShopCatalog()));
          final catalog = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _InfoCard(title: '晶石余额', subtitle: '${catalog.balance} 颗 · 晶石只能靠讲题和悬赏获得', icon: Icons.diamond_outlined),
              const SizedBox(height: 12),
              ...catalog.items.map((item) => _ShopItemCard(item: item, onRedeem: () => _redeem(item))),
              const SizedBox(height: 12),
              FutureBuilder<Map<String, dynamic>>(
                future: _service.fetchLedger(),
                builder: (context, ledger) {
                  final raw = ledger.data?['ledger'];
                  final rows = raw is List ? raw.take(5).toList() : const [];
                  if (rows.isEmpty) return const _EmptyCard('暂无晶石流水。');
                  return _InfoCard(
                    title: '最近流水',
                    subtitle: rows.map((e) => '${e['amount']} · ${e['reason']}').join('\n'),
                    icon: Icons.receipt_long_outlined,
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

class GeekShopPage extends StatefulWidget {
  const GeekShopPage({super.key});

  @override
  State<GeekShopPage> createState() => _GeekShopPageState();
}

class _GeekShopPageState extends State<GeekShopPage> {
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
    await _service.redeem(item.skuId, address: {
      'name': _name.text.trim(),
      'phone': _phone.text.trim(),
      'address': _address.text.trim(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${item.name} 兑换申请已提交，状态 pending。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ScaffoldShell(
      title: '极客学习工具局',
      child: FutureBuilder<ShopCatalog>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _loadingOrError(snapshot, () => setState(() => _future = _service.fetchShopCatalog()));
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageEdge),
            children: [
              _TextField(controller: _name, label: '收货人'),
              _TextField(controller: _phone, label: '电话'),
              _TextField(controller: _address, label: '地址'),
              const SizedBox(height: 12),
              ...snapshot.data!.geekSkus.map((item) => _ShopItemCard(item: item, onRedeem: () => _redeem(item))),
              const SizedBox(height: 12),
              FutureBuilder<Map<String, dynamic>>(
                future: _service.fetchOrders(),
                builder: (context, orders) {
                  final raw = orders.data?['orders'];
                  final rows = raw is List ? raw : const [];
                  return _InfoCard(
                    title: '我的订单',
                    subtitle: rows.isEmpty
                        ? '暂无订单'
                        : rows.map((e) => '${e['skuId']} · ${e['status']}').join('\n'),
                    icon: Icons.local_shipping_outlined,
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LecturePage(section: section)),
    );
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
          if (_error != null) _InfoCard(title: '识别失败', subtitle: _error!, icon: Icons.error_outline),
          if (r != null) ...[
            const SizedBox(height: 12),
            _InfoCard(
              title: '推荐章节 ${r['sectionId']}',
              subtitle: '置信度 ${r['confidence']} · ${r['source']}\n${r['questionPrompt']}',
              icon: Icons.document_scanner_outlined,
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
    await _service.updateProfile({
      'displayName': _display.text.trim(),
      'grade': _grade.text.trim(),
      'schoolName': _school.text.trim(),
      'province': _province.text.trim(),
      'city': _city.text.trim(),
      'district': _district.text.trim(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('资料已保存')));
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
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.pageEdge),
              children: [
                _TextField(controller: _display, label: '展示名'),
                _TextField(controller: _grade, label: '年级'),
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

class _ScaffoldShell extends StatelessWidget {
  const _ScaffoldShell({required this.title, required this.child, this.actions});
  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(child: child),
    );
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

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.subtitle, required this.icon});
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppPalette.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                FormulaText(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(title: '暂无数据', subtitle: text, icon: Icons.inbox_outlined);
  }
}

class _PowerRow extends StatelessWidget {
  const _PowerRow({required this.section});
  final PowerSection section;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: section.sectionId,
      subtitle: '${section.rankTier} · ${section.powerScore} 战力',
      icon: Icons.trending_up,
    );
  }
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FormulaText(challenge.prompt, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FormulaText('错误步骤：${challenge.wrongStep}'),
          const SizedBox(height: 8),
          TextField(
            controller: transcript,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '语音纠错文字（Demo 可手输）'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(Icons.radio_button_checked),
            label: Text('提交圈选与讲解 · +${challenge.rewardCrystals} 晶石'),
          ),
        ],
      ),
    );
  }
}

class _ShopItemCard extends StatelessWidget {
  const _ShopItemCard({required this.item, required this.onRedeem});
  final ShopItem item;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: item.name,
      subtitle: '${item.crystalCost} 晶石 · ${item.type}\n点兑换后返回讲题页可看到笔迹变化。',
      icon: item.type == 'physical' ? Icons.inventory_2_outlined : Icons.brush_outlined,
    ).withButton(onRedeem);
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

extension on Widget {
  Widget withButton(VoidCallback onPressed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        this,
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: onPressed, child: const Text('兑换')),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
