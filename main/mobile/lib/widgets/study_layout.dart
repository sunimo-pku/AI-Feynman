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

/// 区块小标题（不包大面板）。
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
      padding: const EdgeInsets.only(bottom: 8),
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
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.35,
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

/// 单条紧凑行：用于分组列表内，避免「一行一条大卡片」。
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
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color accent;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final vertical = dense ? 8.0 : 10.0;
    Widget row = Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Container(
              width: dense ? 32 : 36,
              height: dense ? 32 : 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: dense ? 18 : 20, color: accent),
            ),
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
                    height: 1.25,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.35,
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

/// 多条 [StudyDenseTile] 合在一个面板里，中间细分割线。
class StudyGroupedPanel extends StatelessWidget {
  const StudyGroupedPanel({
    super.key,
    required this.children,
    this.tone = StudyPanelTone.surface,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
        body.add(const Divider(height: 1, thickness: 1));
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

/// 空状态：轻提示，不用整屏大卡片。
class StudyEmptyHint extends StatelessWidget {
  const StudyEmptyHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppPalette.textSecondary,
          height: 1.45,
        ),
      ),
    );
  }
}

/// 行内反馈条（成功 / 提示 / 错误），替代全宽 InfoCard。
class StudyInlineBanner extends StatelessWidget {
  const StudyInlineBanner({
    super.key,
    required this.message,
    this.tone = StudyPanelTone.quiet,
    this.icon = Icons.info_outline,
  });

  final String message;
  final StudyPanelTone tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final accent = switch (tone) {
      StudyPanelTone.danger => AppPalette.error,
      StudyPanelTone.accent => AppPalette.primaryAccent,
      StudyPanelTone.primary => AppPalette.primary,
      _ => AppPalette.textSecondary,
    };
    return StudyPanel(
      tone: tone,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2 列工具入口（今日 / 更多 Tab 复用）。
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
      child: InkWell(
        borderRadius: AppRadius.cardR,
        onTap: cell.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppPalette.outlineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cell.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(cell.icon, color: cell.color, size: 20),
              ),
              const SizedBox(height: 8),
              Text(
                cell.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              if (cell.subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  cell.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.25,
                    fontSize: 11,
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
