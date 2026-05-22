import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';

/// 多 Agent 角色圆形头像（SVG 人设，替代汉字占位）。
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.role,
    this.size = 52,
    this.ringColor,
    this.ringWidth = 1.5,
    this.pulse = false,
  });

  final AgentRole role;
  final double size;
  final Color? ringColor;
  final double ringWidth;
  final bool pulse;

  static String assetPath(AgentRole role) {
    return switch (role) {
      AgentRole.xiaoming => 'assets/agents/xiaoming.svg',
      AgentRole.daxiong => 'assets/agents/daxiong.svg',
      AgentRole.classLeader || AgentRole.monitor => 'assets/agents/monitor.svg',
      AgentRole.teacher => 'assets/agents/teacher.svg',
      AgentRole.system => 'assets/agents/system.svg',
    };
  }

  static Color accentFor(AgentRole role) {
    return switch (role) {
      AgentRole.xiaoming => AppPalette.secondary,
      AgentRole.daxiong => const Color(0xFFD97706),
      AgentRole.classLeader || AgentRole.monitor => AppPalette.primaryAccent,
      AgentRole.teacher => AppPalette.primary,
      AgentRole.system => AppPalette.textSecondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final border = ringColor ?? AppPalette.outlineSoft;
    final disc = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: border, width: ringWidth),
        boxShadow: [
          BoxShadow(
            color: AppPalette.textPrimary.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipOval(
        child: SvgPicture.asset(
          assetPath(role),
          width: size,
          height: size,
          fit: BoxFit.cover,
          semanticsLabel: _semanticsLabel(role),
          errorBuilder: (context, error, stackTrace) {
            return _AvatarFallback(role: role, size: size);
          },
        ),
      ),
    );
    if (!pulse) return disc;
    return _PulseRing(color: border, child: disc);
  }

  static String _semanticsLabel(AgentRole role) {
    return switch (role) {
      AgentRole.xiaoming => '小明头像',
      AgentRole.daxiong => '大雄头像',
      AgentRole.classLeader || AgentRole.monitor => '班长头像',
      AgentRole.teacher => '李老师头像',
      AgentRole.system => '系统提示',
    };
  }
}

/// SVG 加载失败时的圆形占位（避免空白头像）。
class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.role, required this.size});

  final AgentRole role;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = AgentAvatar.accentFor(role);
    final icon = switch (role) {
      AgentRole.teacher => Icons.school_outlined,
      AgentRole.classLeader || AgentRole.monitor => Icons.verified_outlined,
      AgentRole.xiaoming => Icons.face_outlined,
      AgentRole.daxiong => Icons.face_3_outlined,
      AgentRole.system => Icons.info_outline,
    };
    return Container(
      width: size,
      height: size,
      color: accent.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.48, color: accent),
    );
  }
}

class _PulseRing extends StatefulWidget {
  const _PulseRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
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
                color: widget.color.withValues(alpha: 0.2 + 0.2 * _c.value),
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
