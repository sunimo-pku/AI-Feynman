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
/// 有追问/发言时，在头像左侧显示内联气泡（默认缩略两行，点击展开全文）。
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
    final showBubble = msg != null && msg.text.trim().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showBubble) ...[
          _InlinePeerBubble(
            palette: palette,
            message: msg,
            expanded: isExpanded,
            onToggle: onAvatarTap,
            onPlay: msg.showPlay ? onPlayAudio : null,
            onHighlight:
                msg.highlightStepIds.isNotEmpty ? onHighlightSteps : null,
          ),
          const SizedBox(width: 8),
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

/// 头像左侧内联气泡：默认最多 2 行，点击切换展开/收起。
class _InlinePeerBubble extends StatelessWidget {
  const _InlinePeerBubble({
    required this.palette,
    required this.message,
    required this.expanded,
    required this.onToggle,
    this.onPlay,
    this.onHighlight,
  });

  final _PeerPalette palette;
  final PeerInlineMessage message;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onPlay;
  final void Function(List<String> stepIds)? onHighlight;

  static const double _maxWidth = 200;
  static const int _collapsedLines = 2;

  static String _plainPreview(String raw) {
    return raw
        .replaceAll(RegExp(r'\$\$?'), '')
        .replaceAll(RegExp(r'\\[a-zA-Z]+(\{[^}]*\})?'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
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
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppPalette.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              expanded
                  ? FormulaText(
                    message.text,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    formulaStyle: theme.textTheme.bodySmall?.copyWith(
                      color: palette.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                  : Text(
                    _plainPreview(message.text),
                    maxLines: _collapsedLines,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
              if (expanded && (onPlay != null || onHighlight != null)) ...[
                const SizedBox(height: 6),
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
