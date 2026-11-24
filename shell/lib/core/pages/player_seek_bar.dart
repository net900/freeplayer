import 'dart:io';

import 'package:flutter/material.dart';

import '../sp/models.dart';
import '../theme/tokens.dart';

/// Progress bar with a hover preview taken from the upstream sprite strip
/// (`big_thumbs`). Without a strip it is a plain slider.
class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.value,
    required this.position,
    required this.duration,
    required this.onChanged,
    this.thumbs,
    this.buffered = Duration.zero,
    this.accent = Colors.white,
    this.previewWidth = 168,
  });

  final double value;
  final Duration position;
  final Duration duration;
  final ValueChanged<double>? onChanged;
  final ThumbStrip? thumbs;

  /// Decoder read-ahead, drawn as the dimmer track behind the playhead.
  final Duration buffered;
  final Color accent;
  final double previewWidth;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  double? _hoverX;
  bool _hovering = false;
  // While dragging, the thumb follows the pointer immediately; the seek is
  // sent at most every 150 ms and one final time on release. A remote,
  // encrypted stream cannot absorb dozens of seeks per second.
  double? _dragValue;
  int _lastEmitMs = 0;

  void _emit(double value, {bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastEmitMs < 150) return;
    _lastEmitMs = now;
    widget.onChanged?.call(value);
  }

  double get _bufferedFraction {
    final total = widget.duration.inMilliseconds;
    if (total <= 0 || widget.buffered <= Duration.zero) return 0;
    return (widget.buffered.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final strip = widget.thumbs;
    final shown = (_dragValue ?? widget.value).clamp(0.0, 1.0);
    final dragLabel = _format(
      Duration(
        milliseconds:
            (widget.duration.inMilliseconds * shown).round(),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hover = _hoverX;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_hovering) setState(() => _hovering = true);
          },
          onHover: (event) {
            if (strip == null) return;
            setState(() => _hoverX = event.localPosition.dx);
          },
          onExit: (_) {
            setState(() {
              _hovering = false;
              _hoverX = null;
            });
          },
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // The track thickens on hover: the bar is easier to grab without
              // making the resting chrome heavier.
              TweenAnimationBuilder<double>(
                tween: Tween(end: _hovering ? 4 : 3),
                duration: AppDuration.micro,
                curve: AppDuration.ease,
                builder: (context, trackHeight, child) {
                  return SizedBox(
                    height: 32,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: trackHeight,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                          disabledThumbRadius: 4,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: widget.accent,
                        inactiveTrackColor: Colors.white24,
                        secondaryActiveTrackColor: Colors.white38,
                        thumbColor: Colors.white,
                        valueIndicatorColor: const Color(0xF215181D),
                        valueIndicatorTextStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: AppFontSize.xxs,
                        ),
                        showValueIndicator: _dragValue == null
                            ? ShowValueIndicator.onlyForDiscrete
                            : ShowValueIndicator.onDrag,
                      ),
                      child: Slider(
                        value: shown,
                        secondaryTrackValue: _bufferedFraction,
                        label: dragLabel,
                        onChanged: widget.onChanged == null
                            ? null
                            : (value) {
                                setState(() => _dragValue = value);
                                _emit(value);
                              },
                        onChangeEnd: widget.onChanged == null
                            ? null
                            : (value) {
                                setState(() => _dragValue = null);
                                _emit(value, force: true);
                              },
                      ),
                    ),
                  );
                },
              ),
              if (strip != null && hover != null && width > 0)
                _preview(
                  strip,
                  hover.clamp(0.0, width),
                  width,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _preview(ThumbStrip strip, double x, double width) {
    // Keep the tile's aspect ratio: clamping only the height squashed portrait
    // sprites (136x240 tiles were drawn into a 168x120 box).
    const maxPreviewHeight = 200.0;
    final tileW = strip.tileWidth <= 0 ? 1 : strip.tileWidth;
    final tileH = strip.tileHeight <= 0 ? 1 : strip.tileHeight;
    final naturalWidth = widget.previewWidth;
    final naturalHeight = naturalWidth * tileH / tileW;
    final fit = naturalHeight > maxPreviewHeight
        ? maxPreviewHeight / naturalHeight
        : 1.0;
    final previewW = naturalWidth * fit;
    final previewH = naturalHeight * fit;
    final fraction = width <= 0 ? 0.0 : (x / width).clamp(0.0, 1.0);
    final seconds = widget.duration.inMilliseconds / 1000 * fraction;
    // A source sprite names the seconds each tile covers: tile i is
    // floor(second / interval). Only a strip we built ourselves has no
    // interval, and there the tiles are spread across the episode.
    final tiles = strip.cols * strip.rows;
    if (tiles <= 0) return const SizedBox.shrink();
    final tile = strip.intervalSec > 0
        ? (seconds / strip.intervalSec).floor().clamp(0, tiles - 1)
        : (fraction * tiles).floor().clamp(0, tiles - 1);
    final col = tile % strip.cols;
    final row = tile ~/ strip.cols;
    final left = (x - previewW / 2)
        .clamp(4.0, (width - previewW - 4).clamp(4.0, width))
        .toDouble();
    final time = _format(Duration(milliseconds: (seconds * 1000).round()));
    return Positioned(
      left: left,
      bottom: 36,
      child: IgnorePointer(
        child: Container(
          width: previewW,
          decoration: BoxDecoration(
            color: const Color(0xE6000000),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.sm),
                ),
                child: SizedBox(
                  width: previewW,
                  height: previewH,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      OverflowBox(
                        alignment: Alignment.topLeft,
                        maxWidth: strip.cols * previewW.toDouble(),
                        maxHeight: strip.rows * previewH,
                        child: Transform.translate(
                          offset: Offset(-col * previewW, -row * previewH),
                          child: strip.url.startsWith('http')
                              ? Image.network(
                                  strip.url,
                                  width: strip.cols * previewW.toDouble(),
                                  height: strip.rows * previewH,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (context, error, stack) =>
                                      const SizedBox.shrink(),
                                )
                              : Image.file(
                                  File(strip.url),
                                  width: strip.cols * previewW.toDouble(),
                                  height: strip.rows * previewH,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (context, error, stack) =>
                                      const SizedBox.shrink(),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x2,
                  vertical: 3,
                ),
                child: Text(
                  time,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: AppFontSize.xxs,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _format(Duration value) {
    final total = value.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
