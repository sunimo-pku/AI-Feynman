import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum StudyPanelTone { surface, primary, accent, quiet, danger }

class StudyShell extends StatelessWidget {
  const StudyShell({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.maxWidth,
    this.useSafeArea = true,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;
  final double? maxWidth;
  final bool useSafeArea;

  @override
  Widget build(BuildContext context) {
    Widget body = child;
    if (maxWidth != null) {
      body = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth!),
          child: body,
        ),
      );
    }
    if (useSafeArea) {
      body = SafeArea(child: body);
    }
    return Scaffold(
      backgroundColor: AppPalette.background,
      appBar: AppBar(title: Text(title), actions: actions),
      body: body,
    );
  }
}

class StudyPanel extends StatelessWidget {
  const StudyPanel({
    super.key,
    required this.child,
    this.tone = StudyPanelTone.surface,
    this.padding = const EdgeInsets.all(18),
    this.margin = EdgeInsets.zero,
    this.radius = AppRadius.cardR,
  });

  final Widget child;
  final StudyPanelTone tone;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final colors = _PanelColors.forTone(tone);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: radius,
        border: Border.all(color: colors.border),
        boxShadow:
            tone == StudyPanelTone.quiet
                ? null
                : [
                  BoxShadow(
                    color: AppPalette.textPrimary.withValues(alpha: 0.035),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
      ),
      child: child,
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.action,
    this.accent = AppPalette.primary,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? action;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: 12), action!],
      ],
    );
  }
}

class PrimaryActionBar extends StatelessWidget {
  const PrimaryActionBar({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(12),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return StudyPanel(
      tone: StudyPanelTone.quiet,
      padding: padding,
      child: Row(children: children),
    );
  }
}

class StudyStatPill extends StatelessWidget {
  const StudyStatPill({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.accent = AppPalette.primary,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: AppRadius.buttonR,
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: 6),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                  height: 1.2,
                ),
              ),
              Text(
                value,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelColors {
  const _PanelColors({required this.background, required this.border});

  final Color background;
  final Color border;

  static _PanelColors forTone(StudyPanelTone tone) {
    return switch (tone) {
      StudyPanelTone.primary => _PanelColors(
        background: AppPalette.primary.withValues(alpha: 0.06),
        border: AppPalette.primary.withValues(alpha: 0.12),
      ),
      StudyPanelTone.accent => _PanelColors(
        background: AppPalette.primaryAccent.withValues(alpha: 0.06),
        border: AppPalette.primaryAccent.withValues(alpha: 0.18),
      ),
      StudyPanelTone.quiet => const _PanelColors(
        background: AppPalette.background,
        border: AppPalette.outline,
      ),
      StudyPanelTone.danger => _PanelColors(
        background: AppPalette.error.withValues(alpha: 0.06),
        border: AppPalette.error.withValues(alpha: 0.24),
      ),
      StudyPanelTone.surface => const _PanelColors(
        background: AppPalette.surface,
        border: AppPalette.outlineSoft,
      ),
    };
  }
}
