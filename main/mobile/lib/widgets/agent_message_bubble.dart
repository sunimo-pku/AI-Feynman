import 'package:flutter/material.dart';

import '../data/lecture_models.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';
import 'formula_text.dart';

/// 单条多 Agent 对话气泡：左侧头像 + 右侧昵称 / 文本 / 步骤标签。
///
/// 颜色按 `MOBILE_STYLE.md` 走，避免出现高饱和紫蓝渐变。
class AgentMessageBubble extends StatelessWidget {
  const AgentMessageBubble({
    super.key,
    required this.turn,
    this.onHighlightTap,
    this.isHighlighted = false,
  });

  final AgentTurn turn;
  final VoidCallback? onHighlightTap;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final palette = _palette(turn.role);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(
          color: isHighlighted ? palette.accent : AppPalette.outlineSoft,
          width: isHighlighted ? 1.6 : 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentAvatar(role: turn.role, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      turn.displayName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      palette.roleLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                FormulaText(
                  turn.text,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
                  formulaStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: palette.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (turn.highlightStepIds.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final stepId in turn.highlightStepIds)
                        _StepChip(stepId: stepId, color: palette.accent),
                      if (onHighlightTap != null)
                        TextButton.icon(
                          onPressed: onHighlightTap,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: palette.accent,
                          ),
                          icon: const Icon(Icons.flash_on, size: 16),
                          label: const Text('看这一步'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  _RolePalette _palette(AgentRole role) {
    switch (role) {
      case AgentRole.xiaoming:
        return const _RolePalette(
          surface: Color(0xFFF1F5FF),
          accent: AppPalette.secondary,
          roleLabel: '基础不牢型',
        );
      case AgentRole.daxiong:
        return const _RolePalette(
          surface: Color(0xFFFFF7ED),
          accent: Color(0xFFD97706),
          roleLabel: '计算粗心型',
        );
      case AgentRole.classLeader:
      case AgentRole.monitor:
        // 「班长」在前端有两个等价枚举名：旧名 `classLeader` + 与后端 wire
        // 字符串对齐的 `monitor`。两者共用同一套头像/底色/角色文案，
        // 避免后端返回 `role: "monitor"` 时 switch 不命中（Dart 3
        // 强制 exhaustive 会直接抛 `NoSuchEnumValueError`）。
        return const _RolePalette(
          surface: Color(0xFFF0FDFA),
          accent: AppPalette.primaryAccent,
          roleLabel: '总结建议型',
        );
      case AgentRole.teacher:
        return const _RolePalette(
          surface: Color(0xFFEFF6FF),
          accent: AppPalette.primary,
          roleLabel: '老师 · 把控者',
        );
      case AgentRole.system:
        return const _RolePalette(
          surface: Color(0xFFF8FAFC),
          accent: AppPalette.textSecondary,
          roleLabel: '系统提示',
        );
    }
  }
}

class _RolePalette {
  const _RolePalette({
    required this.surface,
    required this.accent,
    required this.roleLabel,
  });

  final Color surface;
  final Color accent;
  final String roleLabel;
}

class _StepChip extends StatelessWidget {
  const _StepChip({required this.stepId, required this.color});

  final String stepId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '追问步骤 · $stepId',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
