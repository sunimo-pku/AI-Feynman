import 'package:flutter/material.dart';

/// 自习室风格主题（亮色专用，V1 不做暗色）。
///
/// 色板与圆角、字号严格对齐 `MOBILE_STYLE.md`，禁止默认 Material 紫蓝渐变与高饱和电竞色。
class AppPalette {
  static const Color primary = Color(0xFF1E40AF); // 知性深蓝
  static const Color primaryAccent = Color(0xFF0891B2); // 智慧湖青
  static const Color secondary = Color(0xFF3B82F6); // 清朗浅蓝（次要按钮 / 笔迹默认色）
  static const Color background = Color(0xFFFBFBFA); // 温暖暖白 / 纸张色
  static const Color surface = Color(0xFFFFFFFF);
  static const Color outline = Color(0xFFE2E8F0);
  static const Color outlineSoft = Color(0xFFECEFF1);
  static const Color comingSoon = Color(0xFF94A3B8);
  static const Color error = Color(0xFFEF4444);
  static const Color highlight = Color(0xFFFDE047); // step 高亮霓虹光晕
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
}

class AppRadius {
  static const double card = 16;
  static const double large = 24;
  static const double button = 12;
  static const double chip = 8;
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius largeR = BorderRadius.all(Radius.circular(large));
  static const BorderRadius buttonR = BorderRadius.all(Radius.circular(button));
}

class AppSpacing {
  static const double pageEdge = 24;
  static const double moduleGap = 16;
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

    const baseFont = 'Roboto';

    final textTheme = const TextTheme(
      displaySmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: AppPalette.textPrimary,
        height: 1.4,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: AppPalette.textPrimary,
        height: 1.4,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.45,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        color: AppPalette.textPrimary,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        color: AppPalette.textPrimary,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 13,
        color: AppPalette.textSecondary,
        height: 1.5,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppPalette.textPrimary,
        height: 1.4,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: baseFont,
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
          fontWeight: FontWeight.w700,
          color: AppPalette.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppPalette.surface,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.cardR,
          side: BorderSide(color: AppPalette.outlineSoft),
        ),
      ),
      chipTheme: const ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.chip)),
        ),
        side: BorderSide(color: AppPalette.outline),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppPalette.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.primary,
          side: const BorderSide(color: AppPalette.primary, width: 1.2),
          minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
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
      iconTheme: const IconThemeData(color: AppPalette.textPrimary, size: 22),
      dividerTheme: const DividerThemeData(
        color: AppPalette.outline,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppPalette.textPrimary,
        contentTextStyle: TextStyle(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonR),
      ),
    );
  }
}
