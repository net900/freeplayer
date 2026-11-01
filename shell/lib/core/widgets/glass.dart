import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'cover_image.dart';

/// Frosted panel: blur what is behind it, then tint it with the theme's glass
/// colour (dark glass in dark mode, white glass in light mode).
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius = AppRadius.lg,
    this.blur = 18,
    this.tint,
    this.border = true,
    this.constraints,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final double blur;
  final Color? tint;
  final bool border;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    return ConstrainedBox(
      constraints: constraints ?? const BoxConstraints(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: tint ?? colors.glass,
              borderRadius: BorderRadius.circular(radius),
              border: border ? Border.all(color: colors.glassBorder) : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Cheap glass: the same tint and border as [GlassPanel] without a second
/// backdrop blur. Use it for large content areas already sitting on the
/// blurred atmosphere layer.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.radius = AppRadius.lg,
    this.tint,
    this.border = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color? tint;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? colors.glass,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: colors.glassBorder) : null,
      ),
      child: child,
    );
  }
}

/// Full-page cinematic background: the work's cover, heavily blurred, under a
/// theme-aware gradient. Content is laid on top unchanged.
class AtmosphereBackground extends StatelessWidget {
  const AtmosphereBackground({
    super.key,
    required this.child,
    this.cover = '',
    this.seed = '',
    this.intensity = 0.76,
  });

  final Widget child;
  final String cover;
  final String seed;

  /// How visible the blurred cover is (0–1). Higher = more colour.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: colors.bg),
        if (cover.isNotEmpty)
          Opacity(
            opacity: intensity,
            child: CoverImage(
              url: cover,
              seed: seed,
              decodeWidth: 420,
              blurSigma: 44,
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -0.8),
                radius: 1.4,
                colors: [
                  colors.accentWeak,
                  colors.bg.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Keep the blurred cover visible: only enough scrim for text,
              // not a solid page background.
              colors: [
                colors.bg.withValues(alpha: dark ? 0.02 : 0.04),
                colors.bg.withValues(alpha: dark ? 0.16 : 0.20),
                colors.bg.withValues(alpha: dark ? 0.44 : 0.50),
                colors.bg.withValues(alpha: dark ? 0.74 : 0.78),
              ],
              stops: const [0, 0.36, 0.76, 1],
            ),
          ),
        ),
        child,
      ],
    );
  }
}
