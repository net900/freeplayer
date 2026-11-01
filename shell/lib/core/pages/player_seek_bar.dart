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
    this.accent = Colors.white,
    this.previewWidth = 168,
  });

  final double value;
  final Duration position;
  final Duration duration;
  final ValueChanged<double>? onChanged;
  final ThumbStrip? thumbs;
  final Color accent;
  final double previewWidth;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  double? _hoverX;

  @override
  Widget build(BuildContext context) {
    final strip = widget.thumbs;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hover = _hoverX;
        return MouseRegion(
          onHover: (event) {
            if (strip == null) return;
            setState(() => _hoverX = event.localPosition.dx);
          },
          onExit: (_) {
            if (_hoverX != null) setState(() => _hoverX = null);
          },
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              SizedBox(
                height: 32,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: widget.accent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: widget.value,
                    onChanged: widget.onChanged,
                  ),
                ),
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
    // Spread the tiles evenly across the episode instead of trusting a
    // source-supplied interval; sources only hand over the sheet address.
    final tiles = strip.cols * strip.rows;
    final tile = tiles <= 0 ? 0 : (fraction * tiles).floor().clamp(0, tiles - 1);
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
