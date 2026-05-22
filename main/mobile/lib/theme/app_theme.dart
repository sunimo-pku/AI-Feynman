import 'package:flutter/material.dart';

/// 自习室风格主题（亮色专用，V1 不做暗色）。
///
/// 色板与圆角、字号对齐 `MOBILE_STYLE.md`：暖纸底、墨水蓝、纸卡片阴影，禁止
/// 默认 Material 紫蓝渐变与高饱和电竞色。
class AppPalette {
  static const Color primary = Color(0xFF3D5A80); // 墨水蓝
  static const Color primaryAccent = Color(0xFF5B8A8A); // 灰青
  static const Color secondary = Color(0xFF6B8CAE); // 手写笔迹 / 链接
  static const Color background = Color(0xFFF7F3ED); // 暖米纸底
  static const Color surface = Color(0xFFFFFCF7); // 卡片纸面
  static const Color surfaceElevated = Color(0xFFFFFFFF); // 浮层
  static const Color paper = Color(0xFFFFFCF7);
  static const Color canvas = Color(0xFFFFFBF5); // 讲题白板稿纸
  static const Color warmTint = Color(0xFFEDE4D3);
  static const Color ink = Color(0xFF2C3440);
  static const Color outline = Color(0xFFE8E0D4);
  /// 遗留别名：不再用于卡片四边描边，仅作极细分隔线。
  static const Color outlineSoft = Color(0xFFE8E0D4);
  static const Color comingSoon = Color(0xFF94A3B8);
  static const Color error = Color(0xFFEF4444);
  static const Color highlight = Color(0xFFF5E6A8);
  static const Color textPrimary = Color(0xFF2C3440);
  static const Color textSecondary = Color(0xFF6B7280);
}

/// 纸卡片阴影：替代四边描边建立层级。
class AppShadows {
  static List<BoxShadow> get paper => [
    BoxShadow(
      color: AppPalette.ink.withValues(alpha: 0.05),
      blurRadius: 24,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> get paperElevated => [
    BoxShadow(
      color: AppPalette.ink.withValues(alpha: 0.08),
      blurRadius: 28,
      offset: const Offset(0, 10),
    ),
  ];
}

class AppRadius {
  static const double card = 20;
  static const double large = 28;
  static const double button = 14;
  static const double buttonCapsule = 999;
  static const double chip = 10;
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius largeR = BorderRadius.all(Radius.circular(large));
  static const BorderRadius buttonR = BorderRadius.all(Radius.circular(button));
  static const BorderRadius capsuleR = BorderRadius.all(
    Radius.circular(buttonCapsule),
  );
}

class AppSpacing {
  static const double pageEdge = 28;
  static const double moduleGap = 24;
  static const double sectionGap = 32;
  static const double itemGap = 12;
  static const double tightGap = 8;
  static const double touchMin = 48;
}

class AppTheme {
  static ThemeData light() {
    final base = ColorScheme.fromSeed(
      seedColor: AppPalette.primary,
      brightness: Brightness.light,
      primary: AppPalette.primary,
      onPrimary: Colors.white,
      secondary: AppPalette.secondary,
      onSecondary: Colors.white,
      tertiary: AppPalette.primaryAccent,
      surface: AppPalette.surface,
      onSurface: AppPalette.textPrimary,
      error: AppPalette.error,
      outline: AppPalette.outline,
    );

    const textTheme = TextTheme(
      displaySmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: AppPalette.textPrimary,
        height: 1.5,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: AppPalette.textPrimary,
        height: 1.5,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        color: AppPalette.textPrimary,
        height: 1.58,
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        color: AppPalette.textPrimary,
        height: 1.55,
      ),
      bodySmall: TextStyle(
        fontSize: 13,
        color: AppPalette.textSecondary,
        height: 1.55,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: AppPalette.background,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: AppPalette.background,
        foregroundColor: AppPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppPalette.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppPalette.surface,
        margin: EdgeInsets.zero,
        shadowColor: AppPalette.ink.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardR),
      ),
      chipTheme: const ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.chip)),
        ),
        side: BorderSide(color: AppPalette.outline, width: 0.5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppPalette.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.capsuleR),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.primary,
          side: const BorderSide(color: AppPalette.outline, width: 0.8),
          minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.capsuleR),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppPalette.primary,
          minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppPalette.surface,
        indicatorColor: AppPalette.primary.withValues(alpha: 0.10),
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? AppPalette.primary : AppPalette.textSecondary,
          );
        }),
      ),
      iconTheme: const IconThemeData(color: AppPalette.textPrimary, size: 22),
      dividerTheme: DividerThemeData(
        color: AppPalette.ink.withValues(alpha: 0.08),
        thickness: 0.5,
        space: 0.5,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppPalette.ink,
        contentTextStyle: TextStyle(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.capsuleR),
      ),
    );
  }
}
