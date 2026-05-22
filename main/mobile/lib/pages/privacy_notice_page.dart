import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

class PrivacyNoticePage extends StatelessWidget {
  const PrivacyNoticePage({super.key});

  static const ackKey = 'ai_feynman.privacy_ack_v1';

  static Future<bool> ensureAcknowledged(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(ackKey) ?? false) return true;
    if (!context.mounted) return false;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PrivacyNoticePage()),
    );
    if (ok == true) {
      await prefs.setBool(ackKey, true);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: const Text('隐私与权限说明')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageEdge),
        children: [
          const _Card(
            title: '为什么需要麦克风',
            body: '讲题时会采集你的语音，用来实时转写并让 AI 同伴判断什么时候追问。默认不在主界面展示完整转写。',
          ),
          const _Card(
            title: '数据保存在哪里',
            body: '进度和回顾会先保存在本机；登录后会同步到后端，家长端只能查看学习摘要、弱项、回顾和回放。',
          ),
          const _Card(
            title: '家长可见范围',
            body: '家长端看到的是学习进度、讲题摘要、回放时间轴和兑换申请，不提供充值或打赏入口。',
          ),
          const _Card(
            title: '如何清理本地数据',
            body: '退出登录后需重新登录才能继续使用。本地练习数据仍保留在当前账号下；需要彻底清除时，可在系统设置中清除 App 数据。',
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我知道了，继续讲题'),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.body});

  final String title;
  final String body;

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
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
