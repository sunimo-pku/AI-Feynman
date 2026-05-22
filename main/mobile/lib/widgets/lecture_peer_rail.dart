import 'package:flutter/material.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';
import 'formula_text.dart';

/// 讲题页右侧四人头像轨：小明 / 大雄 / 班长 / 李老师。
///
/// 三名同伴外圈颜色表示本轮是否听懂；没听懂时显示可点气泡查看追问理由。
class LecturePeerRail extends StatelessWidget {
  const LecturePeerRail({
    super.key,
    required this.assessments,
    this.playingRole,
    this.activeSpeakingRole,
    this.teacherHasMessage = false,
    this.onPeerTap,
    this.onConfusedBubbleTap,
    this.onTeacherTap,
  });

  final List<PeerAssessment> assessments;
  final AgentRole? playingRole;
  final AgentRole? activeSpeakingRole;
  final bool teacherHasMessage;
  final void Function(AgentRole role)? onPeerTap;
  final void Function(AgentRole role)? onConfusedBubbleTap;
  final VoidCallback? onTeacherTap;

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
      children: [
        for (final role in _peerOrder) ...[
          _PeerAvatarOrb(
            role: role,
            assessment: byRole[role],
            isPlaying: playingRole == role,
            isSpeaking: activeSpeakingRole == role,
            onTap: onPeerTap != null ? () => onPeerTap!(role) : null,
            onBubbleTap:
                onConfusedBubbleTap != null &&
                        byRole[role] != null &&
                        byRole[role]!.understood == false &&
                        byRole[role]!.reason.trim().isNotEmpty
                    ? () => onConfusedBubbleTap!(role)
                    : null,
          ),
          const SizedBox(height: 14),
        ],
        _TeacherAvatarOrb(
          hasMessage: teacherHasMessage,
          isSpeaking: activeSpeakingRole == AgentRole.teacher,
          isPlaying: playingRole == AgentRole.teacher,
          onTap: onTeacherTap,
        ),
      ],
    );
  }
}

/// 点击没听懂同伴后展示的追问气泡（轻量圆角，非整页大卡片）。
class LecturePeerReasonPopover extends StatelessWidget {
  const LecturePeerReasonPopover({
    super.key,
    required this.assessment,
    this.onPlay,
    this.onHighlightSteps,
  });

  final PeerAssessment assessment;
  final VoidCallback? onPlay;
  final VoidCallback? onHighlightSteps;

  @override
  Widget build(BuildContext context) {
    final palette = _PeerPalette.forRole(assessment.role);
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AppPalette.surface.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: AppPalette.textPrimary.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${palette.label}的追问',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: palette.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FormulaText(
              assessment.reason,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.5),
              formulaStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: palette.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (onPlay != null || onHighlightSteps != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (onPlay != null)
                    IconButton(
                      onPressed: onPlay,
                      icon: const Icon(Icons.volume_up_outlined, size: 22),
                      color: palette.accent,
                      tooltip: '听${palette.label}说',
                    ),
                  if (onHighlightSteps != null &&
                      assessment.highlightStepIds.isNotEmpty)
                    IconButton(
                      onPressed: onHighlightSteps,
                      icon: const Icon(Icons.flash_on_outlined, size: 22),
                      color: palette.accent,
                      tooltip: '看相关步骤',
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PeerAvatarOrb extends StatelessWidget {
  const _PeerAvatarOrb({
    required this.role,
    required this.assessment,
    this.isPlaying = false,
    this.isSpeaking = false,
    this.onTap,
    this.onBubbleTap,
  });

  final AgentRole role;
  final PeerAssessment? assessment;
  final bool isPlaying;
  final bool isSpeaking;
  final VoidCallback? onTap;
  final VoidCallback? onBubbleTap;

  @override
  Widget build(BuildContext context) {
    final palette = _PeerPalette.forRole(role);
    final hasData = assessment != null;
    final understood = assessment?.understood ?? false;
    final showBubble =
        hasData &&
        !understood &&
        (assessment!.reason.trim().isNotEmpty);

    final ringColor = switch (true) {
      _ when isSpeaking || isPlaying => AppPalette.primary,
      _ when !hasData => AppPalette.outlineSoft,
      _ when understood => const Color(0xFF16A34A),
      _ => const Color(0xFFEA580C),
    };

    return SizedBox(
      width: 56,
      height: showBubble ? 68 : 56,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: onTap,
            child: _AvatarDisc(
              palette: palette,
              ringColor: ringColor,
              ringWidth: isSpeaking || (hasData && !understood) ? 3 : 1.5,
              pulse: isSpeaking,
            ),
          ),
          if (showBubble)
            Positioned(
              left: -4,
              top: 0,
              child: GestureDetector(
                onTap: onBubbleTap,
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEA580C),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppPalette.textPrimary.withValues(alpha: 0.15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TeacherAvatarOrb extends StatelessWidget {
  const _TeacherAvatarOrb({
    required this.hasMessage,
    this.isSpeaking = false,
    this.isPlaying = false,
    this.onTap,
  });

  final bool hasMessage;
  final bool isSpeaking;
  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const palette = _PeerPalette(
      accent: AppPalette.primary,
      avatar: '师',
      label: '李老师',
    );
    final ringColor =
        isSpeaking || isPlaying
            ? AppPalette.primary
            : hasMessage
            ? AppPalette.primaryAccent
            : AppPalette.outlineSoft;

    return GestureDetector(
      onTap: onTap,
      child: _AvatarDisc(
        palette: palette,
        ringColor: ringColor,
        ringWidth: isSpeaking ? 3 : 1.5,
        pulse: isSpeaking,
      ),
    );
  }
}

class _AvatarDisc extends StatelessWidget {
  const _AvatarDisc({
    required this.palette,
    required this.ringColor,
    required this.ringWidth,
    this.pulse = false,
  });

  final _PeerPalette palette;
  final Color ringColor;
  final double ringWidth;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final disc = Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      child: Text(
        palette.avatar,
        style: TextStyle(
          color: palette.accent,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
    if (!pulse) return disc;
    return _PulseWrapper(color: ringColor, child: disc);
  }
}

class _PulseWrapper extends StatefulWidget {
  const _PulseWrapper({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulseWrapper> createState() => _PulseWrapperState();
}

class _PulseWrapperState extends State<_PulseWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.2 * _c.value),
                blurRadius: 8 + 6 * _c.value,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _PeerPalette {
  const _PeerPalette({
    required this.accent,
    required this.avatar,
    required this.label,
  });

  final Color accent;
  final String avatar;
  final String label;

  static _PeerPalette forRole(AgentRole role) {
    switch (role) {
      case AgentRole.xiaoming:
        return const _PeerPalette(
          accent: AppPalette.secondary,
          avatar: '明',
          label: '小明',
        );
      case AgentRole.daxiong:
        return const _PeerPalette(
          accent: Color(0xFFD97706),
          avatar: '雄',
          label: '大雄',
        );
      case AgentRole.classLeader:
      case AgentRole.monitor:
        return const _PeerPalette(
          accent: AppPalette.primaryAccent,
          avatar: '长',
          label: '班长',
        );
      case AgentRole.teacher:
        return const _PeerPalette(
          accent: AppPalette.primary,
          avatar: '师',
          label: '李老师',
        );
      case AgentRole.system:
        return const _PeerPalette(
          accent: AppPalette.textSecondary,
          avatar: '系',
          label: '系统',
        );
    }
  }
}
