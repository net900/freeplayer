import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Theme-level access to the token set.
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({required this.colors});

  final AppColors colors;

  static AppTokens of(BuildContext context) {
    return Theme.of(context).extension<AppTokens>() ??
        const AppTokens(colors: AppColors.dark);
  }

  @override
  AppTokens copyWith({AppColors? colors}) =>
      AppTokens(colors: colors ?? this.colors);

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(colors: AppColors.lerp(colors, other.colors, t));
  }
}

ThemeData buildAppTheme({
  required Brightness brightness,
  Color? seed,
}) {
  final base = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final accent = seed == null ? base.accent : _deriveAccent(seed, base);
  final colors = base.copyWith(
    accent: accent,
    accentWeak: accent.withValues(alpha: brightness == Brightness.dark ? 0.14 : 0.10),
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: Colors.white,
    secondary: colors.accent,
    onSecondary: Colors.white,
    error: colors.danger,
    onError: Colors.white,
    surface: colors.surface,
    onSurface: colors.text,
  );

  final textTheme = TextTheme(
    bodySmall: TextStyle(
      fontSize: AppFontSize.xs,
      height: AppLineHeight.body,
      color: colors.text2,
    ),
    bodyMedium: TextStyle(
      fontSize: AppFontSize.body,
      height: AppLineHeight.body,
      color: colors.text,
    ),
    bodyLarge: TextStyle(
      fontSize: AppFontSize.bodyLg,
      height: AppLineHeight.body,
      color: colors.text,
    ),
    titleMedium: TextStyle(
      fontSize: AppFontSize.title,
      height: AppLineHeight.title,
      fontWeight: FontWeight.w600,
      color: colors.text,
    ),
    titleLarge: TextStyle(
      fontSize: AppFontSize.h1,
      height: AppLineHeight.title,
      fontWeight: FontWeight.w600,
      color: colors.text,
    ),
    headlineSmall: TextStyle(
      fontSize: AppFontSize.h2,
      height: AppLineHeight.title,
      fontWeight: FontWeight.w700,
      color: colors.text,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.bg,
    canvasColor: colors.surface,
    dividerColor: colors.border,
    disabledColor: colors.text3.withValues(alpha: 0.4),
    fontFamilyFallback: const ['Microsoft YaHei UI', 'Microsoft YaHei'],
    textTheme: textTheme,
    visualDensity: VisualDensity.compact,
    iconTheme: IconThemeData(color: colors.text2, size: 20),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: colors.border),
      ),
      textStyle: TextStyle(color: colors.text, fontSize: AppFontSize.xs),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface2,
      hintStyle: TextStyle(color: colors.text3, fontSize: AppFontSize.body),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x3,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colors.accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, AppSizes.minTouchDesktop),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4,
          vertical: AppSpacing.x3,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.text,
        minimumSize: const Size(0, AppSizes.minTouchDesktop),
        side: BorderSide(color: colors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        minimumSize: const Size(0, AppSizes.minTouchDesktop),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface2,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: colors.border),
      ),
      textStyle: TextStyle(color: colors.text, fontSize: AppFontSize.body),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: colors.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.surface2,
      contentTextStyle: TextStyle(color: colors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.accent),
    // Desktop page changes are instant. Fade/slide transitions read as input
    // lag and show the outgoing page through the incoming one.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: _InstantPageTransitionsBuilder(),
        TargetPlatform.linux: _InstantPageTransitionsBuilder(),
        TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
      },
    ),
    extensions: [AppTokens(colors: colors)],
  );
}

class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// Resolves a source-provided seed to a readable accent for the given
/// brightness. Used by the window chrome outside of `Theme`.
Color readableAccent({required Color seed, required Brightness brightness}) {
  final base = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  return _deriveAccent(seed, base);
}

/// A source may only suggest a seed color. If the seed cannot meet the
/// minimum contrast against the background, the default accent is kept
/// (PRD §5.7.3).
Color _deriveAccent(Color seed, AppColors base) {
  final ratio = _contrastRatio(seed, base.bg);
  if (ratio < 3.0) return base.accent;
  return seed;
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  final r = _channel(color.r);
  final g = _channel(color.g);
  final b = _channel(color.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _channel(double value) {
  return value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

/// Parses `#RRGGBB` or `#AARRGGBB`. Returns null for anything else, including
/// an empty source-provided seed.
Color? colorFromHex(String value) {
  var text = value.trim();
  if (text.startsWith('#')) {
    text = text.substring(1);
  }
  if (text.length == 6) {
    text = 'FF$text';
  }
  if (text.length != 8) return null;
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? null : Color(parsed);
}
