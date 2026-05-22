import 'package:flutter/material.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';
import 'formula_text.dart';

/// 头像旁内联追问文案（由讲题页传入）。
class PeerInlineMessage {
  const PeerInlineMessage({
    required this.text,
    this.highlightStepIds = const [],
    this.showPlay = false,
  });

  final String text;
  final List<String> highlightStepIds;
  final bool showPlay;
}

/// 讲题页右侧四人头像轨：小明 / 大雄 / 班长 / 李老师。
///
/// 有追问时仅在头像旁显示「有话要说」；点击头像展开全文，同时收起其它人。
class LecturePeerRail extends StatelessWidget {
  const LecturePeerRail({
    super.key,
    required this.assessments,
    this.playingRole,
    this.activeSpeakingRole,
    this.teacherHasMessage = false,
    this.expandedRole,
    required this.messageForRole,
    required this.onAvatarTap,
    this.onPlayAudio,
    this.onHighlightSteps,
  });

  final List<PeerAssessment> assessments;
  final AgentRole? playingRole;
  final AgentRole? activeSpeakingRole;
  final bool teacherHasMessage;
  final AgentRole? expandedRole;
  final PeerInlineMessage? Function(AgentRole role) messageForRole;
  final ValueChanged<AgentRole> onAvatarTap;
  final void Function(AgentRole role)? onPlayAudio;
  final void Function(AgentRole role, List<String> stepIds)? onHighlightSteps;

  static const List<AgentRole> _peerOrder = [
    AgentRole.xiaoming,
    AgentRole.daxiong,
    AgentRole.monitor,
  ];

  @override
  Widget build(BuildContext context) {
    final byRole = {for (final a in assessments) a.role: a};
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final role in _peerOrder) ...[
          _PeerRailRow(
            role: role,
            assessment: byRole[role],
            message: messageForRole(role),
            isExpanded: expandedRole == role,
            isPlaying: playingRole == role,
            isSpeaking: activeSpeakingRole == role,
            onAvatarTap: () => onAvatarTap(role),
            onPlayAudio: onPlayAudio != null ? () => onPlayAudio!(role) : null,
            onHighlightSteps:
                onHighlightSteps != null
                    ? (ids) => onHighlightSteps!(role, ids)
                    : null,
          ),
          const SizedBox(height: 12),
        ],
        _PeerRailRow(
          role: AgentRole.teacher,
          assessment: null,
          message: messageForRole(AgentRole.teacher),
          isExpanded: expandedRole == AgentRole.teacher,
          isPlaying: playingRole == AgentRole.teacher,
          isSpeaking: activeSpeakingRole == AgentRole.teacher,
          hasMessageRing: teacherHasMessage,
          onAvatarTap: () => onAvatarTap(AgentRole.teacher),
        ),
      ],
    );
  }
}

class _PeerRailRow extends StatelessWidget {
  const _PeerRailRow({
    required this.role,
    required this.assessment,
    required this.message,
    required this.isExpanded,
    required this.isPlaying,
    required this.isSpeaking,
    required this.onAvatarTap,
    this.hasMessageRing = false,
    this.onPlayAudio,
    this.onHighlightSteps,
  });

  final AgentRole role;
  final PeerAssessment? assessment;
  final PeerInlineMessage? message;
  final bool isExpanded;
  final bool isPlaying;
  final bool isSpeaking;
  final bool hasMessageRing;
  final VoidCallback onAvatarTap;
  final VoidCallback? onPlayAudio;
  final void Function(List<String> stepIds)? onHighlightSteps;

  @override
  Widget build(BuildContext context) {
    final palette = _PeerPalette.forRole(role);
    final hasData = assessment != null;
    final understood = assessment?.understood ?? false;
    final ringColor = switch (true) {
      _ when isSpeaking || isPlaying => AppPalette.primary,
      _ when role == AgentRole.teacher && hasMessageRing => AppPalette.primaryAccent,
      _ when !hasData => AppPalette.outlineSoft,
      _ when understood => const Color(0xFF16A34A),
      _ => const Color(0xFFEA580C),
    };

    final msg = message;
    final hasMessage = msg != null && msg.text.trim().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasMessage && isExpanded) ...[
          _InlinePeerBubble(
            palette: palette,
            message: msg,
            onCollapse: onAvatarTap,
            onPlay: msg.showPlay ? onPlayAudio : null,
            onHighlight:
                msg.highlightStepIds.isNotEmpty ? onHighlightSteps : null,
          ),
          const SizedBox(width: 8),
        ] else if (hasMessage && !isExpanded) ...[
          _PendingMessageChip(
            label: palette.label,
            accent: palette.accent,
            onTap: onAvatarTap,
          ),
          const SizedBox(width: 6),
        ],
        GestureDetector(
          onTap: onAvatarTap,
          child: AgentAvatar(
            role: role,
            ringColor: ringColor,
            ringWidth: isSpeaking || (hasData && !understood) ? 3 : 1.5,
            pulse: isSpeaking,
          ),
        ),
      ],
    );
  }
}

/// 未展开时：轻量「有话要说」入口，不占缩略气泡高度。
class _PendingMessageChip extends StatelessWidget {
  const _PendingMessageChip({
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppPalette.surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 14, color: accent),
              const SizedBox(width: 4),
              Text(
                '有话要说',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: accent,
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

/// 头像左侧展开气泡：全文 + 可选操作。
class _InlinePeerBubble extends StatelessWidget {
  const _InlinePeerBubble({
    required this.palette,
    required this.message,
    required this.onCollapse,
    this.onPlay,
    this.onHighlight,
  });

  final _PeerPalette palette;
  final PeerInlineMessage message;
  final VoidCallback onCollapse;
  final VoidCallback? onPlay;
  final void Function(List<String> stepIds)? onHighlight;

  static const double _maxWidth = 200;
  static const double _maxTextHeight = 180;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCollapse,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: AppPalette.surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.accent.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color: AppPalette.textPrimary.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(-2, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    palette.label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.expand_less,
                    size: 16,
                    color: AppPalette.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _maxTextHeight),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: FormulaText(
                    message.text,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    formulaStyle: theme.textTheme.bodySmall?.copyWith(
                      color: palette.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (onPlay != null || onHighlight != null) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onPlay != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: onPlay,
                        icon: Icon(
                          Icons.volume_up_outlined,
                          size: 18,
                          color: palette.accent,
                        ),
                        tooltip: '听${palette.label}说',
                      ),
                    if (onHighlight != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed:
                            () => onHighlight!(message.highlightStepIds),
                        icon: Icon(
                          Icons.flash_on_outlined,
                          size: 18,
                          color: palette.accent,
                        ),
                        tooltip: '看相关步骤',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PeerPalette {
  const _PeerPalette({required this.accent, required this.label});

  final Color accent;
  final String label;

  static _PeerPalette forRole(AgentRole role) {
    return _PeerPalette(
      accent: AgentAvatar.accentFor(role),
      label: switch (role) {
        AgentRole.xiaoming => '小明',
        AgentRole.daxiong => '大雄',
        AgentRole.classLeader || AgentRole.monitor => '班长',
        AgentRole.teacher => '李老师',
        AgentRole.system => '系统',
      },
    );
  }
}
