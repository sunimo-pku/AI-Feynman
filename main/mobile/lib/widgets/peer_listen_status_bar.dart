import 'package:flutter/material.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';

/// 三名同伴的「听懂 / 没听懂」头像状态条（P1）。
class PeerListenStatusBar extends StatelessWidget {
  const PeerListenStatusBar({
    super.key,
    required this.assessments,
    this.compact = false,
    this.playingRole,
    this.onConfusedPeerTap,
  });

  final List<PeerAssessment> assessments;
  final bool compact;
  final AgentRole? playingRole;
  final void Function(AgentRole role)? onConfusedPeerTap;

  static const List<AgentRole> _order = [
    AgentRole.xiaoming,
    AgentRole.daxiong,
    AgentRole.monitor,
  ];

  @override
  Widget build(BuildContext context) {
    if (assessments.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppPalette.surface,
          borderRadius: AppRadius.cardR,
          border: Border.all(color: AppPalette.outlineSoft),
        ),
        child: Text(
          '提交讲解后，小明、大雄、班长会在这里显示是否听懂',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    final byRole = {for (final a in assessments) a.role: a};
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppPalette.outlineSoft),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _order.length; i++) ...[
            if (i > 0) SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: _PeerStatusChip(
                assessment: byRole[_order[i]],
                role: _order[i],
                isPlaying: playingRole == _order[i],
                onTap:
                    onConfusedPeerTap != null &&
                            byRole[_order[i]] != null &&
                            byRole[_order[i]]!.understood == false
                        ? () => onConfusedPeerTap!(_order[i])
                        : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeerStatusChip extends StatelessWidget {
  const _PeerStatusChip({
    required this.assessment,
    required this.role,
    this.isPlaying = false,
    this.onTap,
  });

  final PeerAssessment? assessment;
  final AgentRole role;
  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final understood = assessment?.understood ?? false;
    final hasData = assessment != null;
    final palette = _palette(role);
    final borderColor =
        isPlaying
            ? AppPalette.primary
            : !hasData
            ? AppPalette.outlineSoft
            : understood
            ? const Color(0xFF16A34A)
            : const Color(0xFFEA580C);

    final chip = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            AgentAvatar(
              role: role,
              size: 44,
              ringColor: borderColor,
              ringWidth: isPlaying || (hasData && !understood) ? 2.4 : 1,
            ),
            if (isPlaying)
              Positioned(
                right: -2,
                bottom: -2,
                child: Icon(
                  Icons.volume_up,
                  size: 14,
                  color: AppPalette.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          palette.label,
          style: Theme.of(context).textTheme.labelSmall,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          isPlaying
              ? '播放中'
              : !hasData
              ? '等待'
              : understood
              ? '听懂了'
              : '没听懂',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color:
                isPlaying
                    ? AppPalette.primary
                    : !hasData
                    ? AppPalette.textSecondary
                    : understood
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFEA580C),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: chip,
        ),
      ),
    );
  }

  _ChipPalette _palette(AgentRole role) {
    return _ChipPalette(
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

class _ChipPalette {
  const _ChipPalette({required this.accent, required this.label});

  final Color accent;
  final String label;
}
