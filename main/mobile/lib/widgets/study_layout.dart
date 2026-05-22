import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';

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
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.radius = AppRadius.cardR,
    this.elevated = false,
  });

  final Widget child;
  final StudyPanelTone tone;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius radius;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final colors = _PanelColors.forTone(tone);
    final showShadow = tone != StudyPanelTone.quiet;
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: radius,
        boxShadow: showShadow
            ? (elevated ? AppShadows.paperElevated : AppShadows.paper)
            : null,
      ),
      child: child,
    );
  }
}

/// 区块标题：左色条 + 文字，无图标底框。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.action,
    this.accent = AppPalette.primary,
    this.showAccentBar = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? action;
  final Color accent;
  final bool showAccentBar;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAccentBar)
          Container(
            width: 3,
            height: subtitle == null ? 20 : 36,
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        if (icon != null && !showAccentBar) ...[
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
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

class StudySectionTitle extends StatelessWidget {
  const StudySectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class StudyDenseTile extends StatelessWidget {
  const StudyDenseTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.accent = AppPalette.primary,
    this.trailing,
    this.onTap,
    this.dense = false,
    this.showIconBox = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color accent;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;
  final bool showIconBox;

  @override
  Widget build(BuildContext context) {
    final vertical = dense ? 8.0 : 10.0;
    Widget row = Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            if (showIconBox)
              Container(
                width: dense ? 32 : 36,
                height: dense ? 32 : 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: dense ? 18 : 20, color: accent),
              )
            else
              Icon(icon, size: dense ? 18 : 20, color: accent),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: row,
      ),
    );
  }
}

class StudyListRow extends StatelessWidget {
  const StudyListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return StudyDenseTile(
      title: title,
      subtitle: subtitle,
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 20, color: AppPalette.textSecondary),
      onTap: onTap,
    );
  }
}

class StudyGroupedPanel extends StatelessWidget {
  const StudyGroupedPanel({
    super.key,
    required this.children,
    this.tone = StudyPanelTone.surface,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    this.margin = EdgeInsets.zero,
  });

  final List<Widget> children;
  final StudyPanelTone tone;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final visible = children.where((w) => w is! SizedBox).toList();
    if (visible.isEmpty) {
      return const SizedBox.shrink();
    }
    final body = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      body.add(visible[i]);
      if (i < visible.length - 1) {
        body.add(const Divider(height: 1));
      }
    }
    return StudyPanel(
      tone: tone,
      padding: padding,
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      ),
    );
  }
}

class StudyEmptyHint extends StatelessWidget {
  const StudyEmptyHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppPalette.textSecondary,
          height: 1.5,
        ),
      ),
    );
  }
}

class StudyInlineBanner extends StatelessWidget {
  const StudyInlineBanner({
    super.key,
    required this.message,
    this.tone = StudyPanelTone.quiet,
    this.icon,
  });

  final String message;
  final StudyPanelTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = switch (tone) {
      StudyPanelTone.danger => AppPalette.error,
      StudyPanelTone.accent => AppPalette.primaryAccent,
      StudyPanelTone.primary => AppPalette.primary,
      _ => AppPalette.textSecondary,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: AppRadius.cardR,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 同伴旁听提示：小明 / 大雄 / 班长会在旁边听。
class StudyCompanionRow extends StatelessWidget {
  const StudyCompanionRow({
    super.key,
    this.message = '小明、大雄和班长会在旁边听你讲',
  });

  final String message;

  static const _roles = [
    AgentRole.xiaoming,
    AgentRole.daxiong,
    AgentRole.monitor,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 32,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < _roles.length; i++)
                  Positioned(
                    left: i * 20.0,
                    child: AgentAvatar(role: _roles[i], size: 32, ringWidth: 1),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StudySoftTag extends StatelessWidget {
  const StudySoftTag({
    super.key,
    required this.text,
    this.accent = AppPalette.primary,
  });

  final String text;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: AppRadius.capsuleR,
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: accent,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 指标标签（叙事化文案，无边框）。
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
    return StudySoftTag(text: '$label · $value', accent: accent);
  }
}

class StudyToolGrid extends StatelessWidget {
  const StudyToolGrid({super.key, required this.cells});

  final List<StudyToolCell> cells;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children:
              cells
                  .map((c) => SizedBox(width: width, child: _StudyToolTile(cell: c)))
                  .toList(),
        );
      },
    );
  }
}

class StudyToolCell {
  const StudyToolCell({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = AppPalette.primary,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
}

class _StudyToolTile extends StatelessWidget {
  const _StudyToolTile({required this.cell});

  final StudyToolCell cell;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surface,
      borderRadius: AppRadius.cardR,
      elevation: 0,
      shadowColor: AppPalette.ink.withValues(alpha: 0.05),
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap: cell.onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            boxShadow: AppShadows.paper,
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(cell.icon, color: cell.color, size: 22),
              const SizedBox(height: 10),
              Text(
                cell.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              if (cell.subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  cell.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.35,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class StudyTabIcon extends StatelessWidget {
  const StudyTabIcon({
    super.key,
    required this.asset,
    this.selected = false,
    this.size = 22,
  });

  final String asset;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppPalette.primary : AppPalette.textSecondary;
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

class _PanelColors {
  const _PanelColors({required this.background});

  final Color background;

  static _PanelColors forTone(StudyPanelTone tone) {
    return switch (tone) {
      StudyPanelTone.primary => _PanelColors(
        background: AppPalette.primary.withValues(alpha: 0.05),
      ),
      StudyPanelTone.accent => _PanelColors(
        background: AppPalette.primaryAccent.withValues(alpha: 0.06),
      ),
      StudyPanelTone.quiet => const _PanelColors(
        background: AppPalette.background,
      ),
      StudyPanelTone.danger => _PanelColors(
        background: AppPalette.error.withValues(alpha: 0.06),
      ),
      StudyPanelTone.surface => const _PanelColors(
        background: AppPalette.surface,
      ),
    };
  }
}
