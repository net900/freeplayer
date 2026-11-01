import 'dart:io' show File;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../local/remote_cover.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'pulse.dart';

/// One cover renderer for the whole app.
///
/// Decodes at the size it is drawn (a 180 px poster no longer decodes a
/// 1080 px image), fades in when the bytes arrive and shows a breathing
/// placeholder instead of an empty hole. [blurSigma] is used for the
/// full-page atmosphere layer.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.decodeWidth,
    this.blurSigma = 0,
    this.seed = '',
    this.radius = 0,
  });

  final String url;
  final BoxFit fit;

  /// Explicit decode width. Defaults to the laid-out width in device pixels.
  final int? decodeWidth;

  /// > 0 blurs the image (page atmosphere). The caller usually also passes a
  /// small [decodeWidth] so the filtered layer stays cheap.
  final double blurSigma;

  /// Stable fallback seed (usually the title) for the gradient cover.
  final String seed;

  final double radius;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // Posters are drawn at a few hundred pixels; decoding 1200 px copies
        // only cost memory and decode time.
        final width = decodeWidth ??
            (constraints.hasBoundedWidth
                ? (constraints.maxWidth * dpr).round().clamp(96, 800)
                : 640);
        Widget image = url.isEmpty
            ? CoverFallback(seed: seed)
            : Image.network(
                url,
                fit: fit,
                cacheWidth: width,
                // Medium is the cheap bilinear path; high resamples with a
                // much more expensive filter on every scroll frame.
                filterQuality:
                    blurSigma > 0 ? FilterQuality.low : FilterQuality.medium,
                frameBuilder: (context, child, frame, syncLoaded) {
                  if (syncLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: AppDuration.overlay,
                    curve: AppDuration.ease,
                    child: child,
                  );
                },
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const PulseBox(radius: 0);
                },
                errorBuilder: (context, error, stack) {
                  // The URL is the fastest way to tell a dead cover from a
                  // format Flutter cannot decode (HEIC); the fallback converts.
                  debugPrint('cover load failed: $url ($error)');
                  return ConvertedCover(
                    url: url,
                    seed: seed,
                    fit: fit,
                    decodeWidth: width,
                  );
                },
              );

        if (blurSigma > 0) {
          image = RepaintBoundary(
            child: ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                  tileMode: TileMode.decal,
                ),
                child: image,
              ),
            ),
          );
        }
        if (radius > 0) {
          image = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: image,
          );
        }
        return image;
      },
    );
  }
}

/// Page backdrop: the cover, softly blurred, under a flat white/black overlay.
/// Content sits on top as normal (no glass panels).
class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({
    super.key,
    required this.cover,
    required this.child,
    this.overlay,
  });

  final String cover;
  final Widget child;

  /// 0–1. Defaults to 0.70 white in light mode and 0.62 black in dark mode.
  final double? overlay;

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover.isEmpty)
          ColoredBox(color: colors.bg)
        else
          CoverImage(
            url: cover,
            fit: BoxFit.cover,
            decodeWidth: 400,
            blurSigma: 12,
          ),
        ColoredBox(
          color: (dark ? Colors.black : Colors.white)
              .withValues(alpha: overlay ?? (dark ? 0.72 : 0.84)),
        ),
        child,
      ],
    );
  }
}

/// Last resort for artwork Flutter cannot decode (HEIC): convert it once with
/// the bundled ffmpeg and show the local JPEG. Falls back to the gradient when
/// there is nothing to convert.
class ConvertedCover extends StatefulWidget {
  const ConvertedCover({
    super.key,
    required this.url,
    required this.seed,
    this.fit = BoxFit.cover,
    this.decodeWidth,
  });

  final String url;
  final String seed;
  final BoxFit fit;
  final int? decodeWidth;

  @override
  State<ConvertedCover> createState() => _ConvertedCoverState();
}

class _ConvertedCoverState extends State<ConvertedCover> {
  Future<String?>? _future;

  @override
  void initState() {
    super.initState();
    _future = RemoteCover.ensure(widget.url);
  }

  @override
  void didUpdateWidget(ConvertedCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = RemoteCover.ensure(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null) return CoverFallback(seed: widget.seed);
        return Image.file(
          File(path),
          fit: widget.fit,
          cacheWidth: widget.decodeWidth,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stack) =>
              CoverFallback(seed: widget.seed),
        );
      },
    );
  }
}

/// Deterministic gradient stand-in when a source has no cover or the image
/// fails to load.
class CoverFallback extends StatelessWidget {
  const CoverFallback({super.key, this.seed = ''});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final hue = (seed.hashCode % 360).abs().toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.30, 0.32).toColor();
    final deep = HSLColor.fromAHSL(1, (hue + 24) % 360, 0.34, 0.16).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, deep],
        ),
      ),
      child: seed.isEmpty
          ? const SizedBox.expand()
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.x2),
                child: Text(
                  seed,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: AppFontSize.xxs,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
    );
  }
}
