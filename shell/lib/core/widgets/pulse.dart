import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Shimmering placeholder used by skeletons and cover loading states.
///
/// A single translucent gradient sweeps across the box; the highlight is
/// semi-transparent so the page backdrop shows through instead of the
/// skeleton reading as a solid grey card.
class PulseBox extends StatefulWidget {
  const PulseBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadius.md,
    this.child,
  });

  final double? width;
  final double? height;
  final double radius;
  final Widget? child;

  @override
  State<PulseBox> createState() => _PulseBoxState();
}

class _PulseBoxState extends State<PulseBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  Timer? _settle;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    // A shimmer that repeats forever keeps repainting every visible
    // placeholder, even when a cover never arrives. After a few seconds the
    // still gradient reads the same and costs nothing.
    _settle = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _controller.stop();
      setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    final base = colors.surface3.withValues(alpha: 0.55);
    final highlight = Color.lerp(colors.surface3, colors.text3, 0.30)!
        .withValues(alpha: 0.55);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _settled ? 0.5 : _controller.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.6 + 3.2 * t, 0),
              end: Alignment(-0.6 + 3.2 * t, 0),
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
