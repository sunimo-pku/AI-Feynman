import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 讲题页圆形工具按钮（48dp 触控区，无大矩形面板）。
class LectureOrbButton extends StatelessWidget {
  const LectureOrbButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.filled = false,
    this.accent = AppPalette.primary,
    this.pulse = false,
    this.loading = false,
    this.size = 48,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool filled;
  final Color accent;
  final bool pulse;
  final bool loading;
  final double size;

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: filled ? accent : AppPalette.surface.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: filled ? 2 : 0,
        shadowColor: AppPalette.textPrimary.withValues(alpha: 0.12),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: loading ? null : onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: filled ? accent : AppPalette.outlineSoft,
                width: filled ? 0 : 1,
              ),
            ),
            child: Center(
              child:
                  loading
                      ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: filled ? Colors.white : accent,
                        ),
                      )
                      : Icon(
                        icon,
                        size: 22,
                        color: filled ? Colors.white : accent,
                      ),
            ),
          ),
        ),
      ),
    );

    Widget orb = pulse ? _PulsingRing(color: accent, child: child) : child;
    if (tooltip != null && tooltip!.isNotEmpty) {
      orb = Tooltip(message: tooltip!, child: orb);
    }
    return orb;
  }
}

class _PulsingRing extends StatefulWidget {
  const _PulsingRing({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
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
      builder: (context, child) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                  width: 2.5,
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}
