import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/theme/app_theme.dart';
import 'package:free_player/core/theme/tokens.dart';

void main() {
  test('both themes expose the token extension', () {
    final light = buildAppTheme(brightness: Brightness.light);
    final dark = buildAppTheme(brightness: Brightness.dark);
    expect(light.extension<AppTokens>()!.colors.bg, AppColors.light.bg);
    expect(dark.extension<AppTokens>()!.colors.bg, AppColors.dark.bg);
  });

  test('unreadable source seed falls back to the default accent', () {
    final theme = buildAppTheme(
      brightness: Brightness.dark,
      seed: AppColors.dark.bg,
    );
    expect(theme.extension<AppTokens>()!.colors.accent, AppColors.dark.accent);
  });

  test('contrast-safe source seed is applied', () {
    const seed = Color(0xFF00FF88);
    final theme = buildAppTheme(brightness: Brightness.dark, seed: seed);
    expect(theme.extension<AppTokens>()!.colors.accent, seed);
  });
}
