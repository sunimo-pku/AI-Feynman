import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 实时讲题音频控制面板（第九轮）。
///
/// 一个无状态的纯展示组件，只负责把当前 [RealtimeAudioPanelState] 渲染成
/// 学生能看懂的中文短句 + 主行动按钮；具体的"开始 / 暂停 / 结束"逻辑
/// 由调用方 [LecturePage] 实现并通过回调注入。
///
/// 设计原则：
///   * 视觉**克制**：不在主路径上展示任何 ASR 转写内容（brief 第 9 节
///     "禁止默认展示完整 ASR 转写文本"）；
///   * 主按钮 48dp 触控热区，符合 `MOBILE_STYLE.md` 平板优先；
///   * 状态文字 ≤ 18 字，平板远距阅读不费力；
///   * 错误 / 权限拒绝走副文本 + 兜底"用文字提交"按钮，不破坏白板。
class RealtimeAudioPanel extends StatelessWidget {
  const RealtimeAudioPanel({
    super.key,
    required this.state,
    required this.onStart,
    required this.onStop,
    required this.onEndQuestion,
    required this.onManualPause,
    this.onFallbackSubmit,
    this.failureReason,
    this.canManualPause = false,
  });

  final RealtimeAudioPanelState state;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onEndQuestion;
  final VoidCallback onManualPause;

  /// "我讲到这里，请 AI 追问"按钮可用条件：state 是 listening 且有最少
  /// 几秒音频缓冲 —— 由调用方计算后传入。
  final bool canManualPause;

  /// 录音失败 / 权限拒绝时的"换一种方式"兜底入口：调用方可以打开传统
  /// 「提交讲解」表单（基于打字 + 手写）。
  final VoidCallback? onFallbackSubmit;

  /// 当 state 是 [RealtimeAudioPanelState.failed] /
  /// [RealtimeAudioPanelState.permissionDenied] 时显示的副文本。
  final String? failureReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _paletteFor(state);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StatusIcon(state: state, color: palette.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _titleFor(state),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitleFor(state, failureReason: failureReason),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (state == RealtimeAudioPanelState.listening ||
                  state == RealtimeAudioPanelState.paused ||
                  state == RealtimeAudioPanelState.thinking ||
                  state == RealtimeAudioPanelState.aiSpeaking ||
                  state == RealtimeAudioPanelState.interrupted)
                _PulseDot(color: palette.accent),
            ],
          ),
          const SizedBox(height: 12),
          _buildActionRow(context, palette),
        ],
      ),
    );
  }

  Widget _buildActionRow(BuildContext context, _PaletteVariant palette) {
    switch (state) {
      case RealtimeAudioPanelState.idle:
        return FilledButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.mic),
          label: const Text('开始讲题'),
        );
      case RealtimeAudioPanelState.listening:
      case RealtimeAudioPanelState.paused:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canManualPause ? onManualPause : null,
                icon: const Icon(Icons.front_hand_outlined),
                label: const Text('我讲到这里'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: onEndQuestion,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('结束本题'),
              ),
            ),
          ],
        );
      case RealtimeAudioPanelState.thinking:
        return OutlinedButton.icon(
          onPressed: onStop,
          icon: const Icon(Icons.pause),
          label: const Text('暂停倾听'),
        );
      case RealtimeAudioPanelState.aiSpeaking:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onManualPause,
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('我来回答'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: onEndQuestion,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('结束本题'),
              ),
            ),
          ],
        );
      case RealtimeAudioPanelState.interrupted:
        return OutlinedButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.mic),
          label: const Text('继续讲'),
        );
      case RealtimeAudioPanelState.disconnected:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ),
            if (onFallbackSubmit != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onFallbackSubmit,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('用文字提交'),
                ),
              ),
            ],
          ],
        );
      case RealtimeAudioPanelState.permissionDenied:
      case RealtimeAudioPanelState.failed:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.refresh),
                label: const Text('再试一次'),
              ),
            ),
            if (onFallbackSubmit != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onFallbackSubmit,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('用文字提交'),
                ),
              ),
            ],
          ],
        );
    }
  }

  String _titleFor(RealtimeAudioPanelState s) {
    switch (s) {
      case RealtimeAudioPanelState.idle:
        return '准备好开始讲题了吗？';
      case RealtimeAudioPanelState.listening:
        return '正在听你讲...';
      case RealtimeAudioPanelState.paused:
        return '检测到停顿，AI 正在想问题...';
      case RealtimeAudioPanelState.thinking:
        return 'AI 正在想问题...';
      case RealtimeAudioPanelState.aiSpeaking:
        return 'AI 同伴正在说话';
      case RealtimeAudioPanelState.interrupted:
        return '你打断了 AI，我继续听你讲';
      case RealtimeAudioPanelState.disconnected:
        return '连接断开，白板还在，可以重新开始';
      case RealtimeAudioPanelState.permissionDenied:
        return '麦克风权限被拒绝';
      case RealtimeAudioPanelState.failed:
        return '录音遇到问题';
    }
  }

  String _subtitleFor(
    RealtimeAudioPanelState s, {
    String? failureReason,
  }) {
    switch (s) {
      case RealtimeAudioPanelState.idle:
        return '点击「开始讲题」，一边写白板一边口头讲解你的思路。';
      case RealtimeAudioPanelState.listening:
        return '你可以一边写一边讲，自然停顿后 AI 同伴会追问。';
      case RealtimeAudioPanelState.paused:
        return '保持安静一会儿，AI 同伴马上来追问；想说就直接说话。';
      case RealtimeAudioPanelState.thinking:
        return 'AI 正在根据你刚才讲的内容写问题。';
      case RealtimeAudioPanelState.aiSpeaking:
        return '可以直接开口或者落笔，AI 会停下来听你讲。';
      case RealtimeAudioPanelState.interrupted:
        return 'AI 已经停下来了，等你讲完它再继续。';
      case RealtimeAudioPanelState.disconnected:
        return '后端连接断了，你写的内容不会丢失，可以重连。';
      case RealtimeAudioPanelState.permissionDenied:
        return failureReason ?? '请到系统设置 → 应用权限里允许「麦克风」后再试。';
      case RealtimeAudioPanelState.failed:
        return failureReason ?? '录音库初始化失败，可以切到文字提交继续学习。';
    }
  }

  _PaletteVariant _paletteFor(RealtimeAudioPanelState s) {
    switch (s) {
      case RealtimeAudioPanelState.idle:
        return const _PaletteVariant(
          background: AppPalette.surface,
          border: AppPalette.outlineSoft,
          accent: AppPalette.textPrimary,
        );
      case RealtimeAudioPanelState.listening:
        return _PaletteVariant(
          background: AppPalette.primaryAccent.withValues(alpha: 0.06),
          border: AppPalette.primaryAccent.withValues(alpha: 0.30),
          accent: AppPalette.primaryAccent,
        );
      case RealtimeAudioPanelState.paused:
      case RealtimeAudioPanelState.thinking:
      case RealtimeAudioPanelState.aiSpeaking:
        return _PaletteVariant(
          background: AppPalette.primary.withValues(alpha: 0.06),
          border: AppPalette.primary.withValues(alpha: 0.30),
          accent: AppPalette.primary,
        );
      case RealtimeAudioPanelState.interrupted:
        return _PaletteVariant(
          background: AppPalette.secondary.withValues(alpha: 0.08),
          border: AppPalette.secondary.withValues(alpha: 0.30),
          accent: AppPalette.secondary,
        );
      case RealtimeAudioPanelState.disconnected:
      case RealtimeAudioPanelState.failed:
      case RealtimeAudioPanelState.permissionDenied:
        return _PaletteVariant(
          background: AppPalette.error.withValues(alpha: 0.06),
          border: AppPalette.error.withValues(alpha: 0.30),
          accent: AppPalette.error,
        );
    }
  }
}

class _PaletteVariant {
  const _PaletteVariant({
    required this.background,
    required this.border,
    required this.accent,
  });

  final Color background;
  final Color border;
  final Color accent;
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.state, required this.color});

  final RealtimeAudioPanelState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final icon = switch (state) {
      RealtimeAudioPanelState.idle => Icons.mic_none_outlined,
      RealtimeAudioPanelState.listening => Icons.graphic_eq,
      RealtimeAudioPanelState.paused => Icons.psychology_alt_outlined,
      RealtimeAudioPanelState.thinking => Icons.psychology_outlined,
      RealtimeAudioPanelState.aiSpeaking => Icons.campaign_outlined,
      RealtimeAudioPanelState.interrupted => Icons.front_hand_outlined,
      RealtimeAudioPanelState.disconnected => Icons.wifi_off_rounded,
      RealtimeAudioPanelState.permissionDenied => Icons.mic_off_outlined,
      RealtimeAudioPanelState.failed => Icons.error_outline,
    };
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

/// 极简呼吸点：在 listening / thinking / aiSpeaking 时给学生"系统活着"
/// 的视觉锚点。**不**用复杂动画曲线，避免在低端平板上卡帧。
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.4 + 0.5 * t),
            shape: BoxShape.circle,
          ),
          child: const SizedBox(width: 10, height: 10),
        );
      },
    );
  }
}

/// 与 [LecturePage] 内部 ``_LiveStatus`` 桥接的 UI 状态枚举。
///
/// 故意**不**和 service 层的 [AudioStreamStatus] / [LiveConnectionState]
/// 直连：UI 层经常需要根据多个信号组合（"WS 已连 + 录音 listening + 没
/// thinking" → listening；"WS 已断" → disconnected 不管录音状态）。
enum RealtimeAudioPanelState {
  idle,
  listening,
  paused,
  thinking,
  aiSpeaking,
  interrupted,
  disconnected,
  permissionDenied,
  failed,
}
