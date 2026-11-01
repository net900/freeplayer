import 'package:flutter/material.dart';

/// Design tokens are the only source of colors, spacing, radii and type sizes.
/// Business code must not contain hex values or magic numbers (PRD §5.7.2).
@immutable
class AppColors {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accentWeak,
    required this.danger,
    required this.success,
    required this.badgeNew,
    required this.badgeGold,
    required this.badgeInfo,
    required this.badgeHot,
    required this.glass,
    required this.glassBorder,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color border;
  final Color text;
  final Color text2;
  final Color text3;
  final Color accent;
  final Color accentWeak;
  final Color danger;
  final Color success;

  /// Semantic badge colours. Labels are classified in `AppBadge`; every page
  /// uses the same mapping so 新 is green everywhere and 集数 stays neutral.
  final Color badgeNew;
  final Color badgeGold;
  final Color badgeInfo;
  final Color badgeHot;

  /// Frosted surfaces (Netflix-style panels).
  final Color glass;
  final Color glassBorder;

  static AppColors lerp(AppColors a, AppColors b, double t) {
    return AppColors(
      bg: Color.lerp(a.bg, b.bg, t)!,
      surface: Color.lerp(a.surface, b.surface, t)!,
      surface2: Color.lerp(a.surface2, b.surface2, t)!,
      surface3: Color.lerp(a.surface3, b.surface3, t)!,
      border: Color.lerp(a.border, b.border, t)!,
      text: Color.lerp(a.text, b.text, t)!,
      text2: Color.lerp(a.text2, b.text2, t)!,
      text3: Color.lerp(a.text3, b.text3, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
      accentWeak: Color.lerp(a.accentWeak, b.accentWeak, t)!,
      danger: Color.lerp(a.danger, b.danger, t)!,
      success: Color.lerp(a.success, b.success, t)!,
      badgeNew: Color.lerp(a.badgeNew, b.badgeNew, t)!,
      badgeGold: Color.lerp(a.badgeGold, b.badgeGold, t)!,
      badgeInfo: Color.lerp(a.badgeInfo, b.badgeInfo, t)!,
      badgeHot: Color.lerp(a.badgeHot, b.badgeHot, t)!,
      glass: Color.lerp(a.glass, b.glass, t)!,
      glassBorder: Color.lerp(a.glassBorder, b.glassBorder, t)!,
    );
  }

  AppColors copyWith({Color? accent, Color? accentWeak}) {
    return AppColors(
      bg: bg,
      surface: surface,
      surface2: surface2,
      surface3: surface3,
      border: border,
      text: text,
      text2: text2,
      text3: text3,
      accent: accent ?? this.accent,
      accentWeak: accentWeak ?? this.accentWeak,
      danger: danger,
      success: success,
      badgeNew: badgeNew,
      badgeGold: badgeGold,
      badgeInfo: badgeInfo,
      badgeHot: badgeHot,
      glass: glass,
      glassBorder: glassBorder,
    );
  }

  static const AppColors dark = AppColors(
    bg: Color(0xFF0D0F12),
    surface: Color(0xFF15181D),
    surface2: Color(0xFF1C2027),
    surface3: Color(0xFF242932),
    border: Color(0xFF282E37),
    text: Color(0xFFECEEF2),
    text2: Color(0xFFA2AAB8),
    text3: Color(0xFF6C7482),
    accent: Color(0xFFE8453C),
    accentWeak: Color(0x24E8453C),
    danger: Color(0xFFF05252),
    success: Color(0xFF3DBE7A),
    badgeNew: Color(0xFF34C77B),
    badgeGold: Color(0xFFF0B44C),
    badgeInfo: Color(0xFF9B8AFB),
    badgeHot: Color(0xFFFF7A45),
    glass: Color(0x4D000000),
    glassBorder: Color(0x40FFFFFF),
  );

  static const AppColors light = AppColors(
    bg: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0F2F5),
    surface3: Color(0xFFE6E9EE),
    border: Color(0xFFDDE1E7),
    text: Color(0xFF14181D),
    text2: Color(0xFF5B6472),
    text3: Color(0xFF8C95A3),
    accent: Color(0xFFD63A31),
    accentWeak: Color(0x1AD63A31),
    danger: Color(0xFFD92D20),
    success: Color(0xFF12A150),
    badgeNew: Color(0xFF0F9D58),
    badgeGold: Color(0xFFB07B18),
    badgeInfo: Color(0xFF6D5BD0),
    badgeHot: Color(0xFFD9480F),
    glass: Color(0x40FFFFFF),
    glassBorder: Color(0x26000000),
  );
}

abstract final class AppSpacing {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;
}

abstract final class AppRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double pill = 999;
}

abstract final class AppFontSize {
  static const double xxs = 11;
  static const double xs = 12;
  static const double body = 13.5;
  static const double bodyLg = 15;
  static const double title = 17;
  static const double h1 = 21;
  static const double h2 = 24;
}

abstract final class AppLineHeight {
  static const double body = 1.6;
  static const double title = 1.25;
}

abstract final class AppDuration {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration page = Duration(milliseconds: 180);
  static const Duration overlay = Duration(milliseconds: 240);
  static const Curve ease = Cubic(0.2, 0.8, 0.2, 1);
}

abstract final class AppSizes {
  static const double topBar = 56;
  static const double sidebar = 232;
  static const double sidebarCollapsed = 68;
  static const double contentPadX = 26;
  static const double contentPadY = 30;
  static const double focusRing = 2;
  static const double skeletonMinDelayMs = 300;
  static const double minTouchDesktop = 32;
  static const double compactWidth = 1100;
  static const double drawerWidth = 820;
  static const double posterAspect = 3 / 4;
  static const double playerAspect = 16 / 9;
}

/// Standard shadow values from PRD §5.7.2.
abstract final class AppShadows {
  static const List<BoxShadow> light = [
    BoxShadow(color: Color(0x1F14181D), blurRadius: 28, offset: Offset(0, 8)),
  ];
  static const List<BoxShadow> dark = [
    BoxShadow(color: Color(0x73000000), blurRadius: 28, offset: Offset(0, 8)),
  ];
}
