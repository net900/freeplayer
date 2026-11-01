import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/pulse.dart';

/// Loading placeholders. Their shape mirrors the content they replace.
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.maxCrossAxisExtent = 180});

  final double maxCrossAxisExtent;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.x1),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: AppSpacing.x4,
        crossAxisSpacing: AppSpacing.x4,
        childAspectRatio: AppSizes.posterAspect,
      ),
      itemCount: 12,
      itemBuilder: (context, index) => const SkeletonBox(),
    );
  }
}

class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 8,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.x3),
      itemBuilder: (context, index) =>
          const SkeletonBox(height: 64, radius: AppRadius.md),
    );
  }
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadius.md,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return PulseBox(width: width, height: height, radius: radius);
  }
}

/// Five small frames rising and falling in sequence: a quiet, film-strip
/// loading mark instead of a spinner.
class LoadingMark extends StatefulWidget {
  const LoadingMark({super.key, this.compact = false});

  final bool compact;

  @override
  State<LoadingMark> createState() => _LoadingMarkState();
}

class _LoadingMarkState extends State<LoadingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final width = widget.compact ? 3.0 : 4.0;
    final height = widget.compact ? 12.0 : 16.0;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < 5; i++) ...[
              _Frame(
                width: width,
                height: height,
                color: tokens.colors.accent,
                phase: (_controller.value + i * 0.16) % 1,
              ),
              if (i < 4) SizedBox(width: widget.compact ? 2 : 3),
            ],
          ],
        );
      },
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.width,
    required this.height,
    required this.color,
    required this.phase,
  });

  final double width;
  final double height;
  final Color color;
  final double phase;

  @override
  Widget build(BuildContext context) {
    final wave = (sin(phase * 2 * pi) + 1) / 2; // 0..1
    final scale = 0.45 + 0.55 * wave;
    return Container(
      width: width,
      height: height * scale,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.35 + 0.6 * wave),
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

/// Compact loading line used by sheets and the detail episode grid.
class LoadingLine extends StatelessWidget {
  const LoadingLine({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LoadingMark(compact: compact),
        const SizedBox(width: AppSpacing.x2),
        Text(
          '正在加载',
          style: TextStyle(
            fontSize: compact ? AppFontSize.xxs : AppFontSize.xs,
            color: tokens.colors.text3,
          ),
        ),
      ],
    );
  }
}

/// Skeleton plus a quiet loading mark, used wherever a page is fetching data.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.skeleton = const SkeletonGrid()});

  final Widget skeleton;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.x3),
          child: Center(child: LoadingLine()),
        ),
        Expanded(child: skeleton),
      ],
    );
  }
}
