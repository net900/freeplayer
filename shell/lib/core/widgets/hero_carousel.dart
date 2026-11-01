import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'cover_image.dart';

/// Editorial hero strip for catalogue home pages.
///
/// One wide card per recommended title, with the poster kept intact beside a
/// blurred backdrop so portrait artwork never gets stretched. Auto-advances
/// while the pointer is idle; a drag pauses it and it resumes afterwards.
class HeroCarousel extends StatefulWidget {
  const HeroCarousel({
    super.key,
    required this.items,
    required this.onTap,
  });

  final List<Item> items;
  final void Function(Item item) onTap;

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  final PageController _controller = PageController();
  Timer? _timer;
  int _index = 0;
  bool _held = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    if (!mounted || widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (_held || !mounted || !_controller.hasClients) return;
      final next = (_index + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 520),
        curve: AppDuration.ease,
      );
    });
  }

  void _pause() {
    _held = true;
    _timer?.cancel();
  }

  void _resume() {
    if (!_held) return;
    _held = false;
    _start();
  }

  void _step(int delta) {
    if (!_controller.hasClients || widget.items.length < 2) return;
    _pause();
    final next = (_index + delta + widget.items.length) % widget.items.length;
    _controller
        .animateToPage(
          next,
          duration: const Duration(milliseconds: 320),
          curve: AppDuration.ease,
        )
        .whenComplete(_resume);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = width < 620
            ? (width * 0.62).clamp(230.0, 320.0)
            : (width * 0.34).clamp(220.0, 360.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MouseRegion(
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: NotificationListener<UserScrollNotification>(
                        onNotification: (notification) {
                          if (notification.direction == ScrollDirection.idle) {
                            _resume();
                          } else {
                            _pause();
                          }
                          return false;
                        },
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context).copyWith(
                            dragDevices: const {
                              PointerDeviceKind.touch,
                              PointerDeviceKind.mouse,
                              PointerDeviceKind.trackpad,
                              PointerDeviceKind.stylus,
                            },
                          ),
                          child: PageView.builder(
                            controller: _controller,
                            itemCount: items.length,
                            onPageChanged: (index) =>
                                setState(() => _index = index),
                            itemBuilder: (context, index) => _HeroCard(
                              item: items[index],
                              compact: width < 620,
                              onTap: () => widget.onTap(items[index]),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (items.length > 1) ...[
                      Positioned(
                        left: AppSpacing.x3,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: _Arrow(
                            icon: Icons.chevron_left,
                            visible: _hover,
                            onTap: () => _step(-1),
                          ),
                        ),
                      ),
                      Positioned(
                        right: AppSpacing.x3,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: _Arrow(
                            icon: Icons.chevron_right,
                            visible: _hover,
                            onTap: () => _step(1),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (items.length > 1) ...[
              const SizedBox(height: AppSpacing.x3),
              _Dots(
                count: items.length,
                index: _index,
                onTap: (index) {
                  _pause();
                  _controller.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 360),
                    curve: AppDuration.ease,
                  );
                  _resume();
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.item,
    required this.compact,
    required this.onTap,
  });

  final Item item;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final score = _number(item.extra['score']);
    final backdrop = _text(item.extra['backdrop']);
    final hasBackdrop = backdrop.isNotEmpty;
    final meta = <String>[
      if (_text(item.extra['year']).isNotEmpty) _text(item.extra['year']),
      if (_text(item.extra['area']).isNotEmpty) _text(item.extra['area']),
      for (final tag in item.tags.take(2)) tag,
    ];

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.x1),
      child: Material(
        color: tokens.colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CoverImage(
                url: hasBackdrop ? backdrop : item.cover,
                fit: BoxFit.cover,
                blurSigma: hasBackdrop ? 0 : 26,
                decodeWidth: hasBackdrop ? 1300 : 420,
                seed: item.title,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xF20A0C10),
                      Color(0xB30A0C10),
                      Color(0x1A0A0C10),
                    ],
                    stops: [0, 0.55, 1],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x6,
                  AppSpacing.x6,
                  AppSpacing.x6,
                  AppSpacing.x6,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '推荐',
                            style: TextStyle(
                              fontSize: AppFontSize.xxs,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                              color: tokens.colors.accent,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.x2),
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact
                                  ? AppFontSize.h1
                                  : AppFontSize.h2,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                              color: Colors.white,
                            ),
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.x2),
                            Text(
                              meta.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: AppFontSize.xs,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                          if (!compact && item.description.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.x1),
                            Text(
                              item.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: AppFontSize.xs,
                                height: 1.5,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.x3),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FilledButton.icon(
                                onPressed: onTap,
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('播放'),
                              ),
                              if (score > 0) ...[
                                const SizedBox(width: AppSpacing.x3),
                                Icon(
                                  Icons.star_rounded,
                                  size: 16,
                                  color: tokens.colors.badgeGold,
                                ),
                                const SizedBox(width: AppSpacing.x1),
                                Text(
                                  score.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: AppFontSize.xs,
                                    fontWeight: FontWeight.w600,
                                    color: tokens.colors.badgeGold,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: AppSpacing.x6),
                      SizedBox(
                        width: 108,
                        child: AspectRatio(
                          aspectRatio: AppSizes.posterAspect,
                          child: ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppRadius.md),
                            child: CoverImage(
                              url: item.cover,
                              seed: item.title,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _text(Object? value) => value == null ? '' : value.toString();

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.icon,
    required this.visible,
    required this.onTap,
  });

  final IconData icon;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0.55,
      duration: AppDuration.micro,
      child: Material(
        color: const Color(0x66000000),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x2),
            child: Icon(icon, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.index,
    required this.onTap,
  });

  final int count;
  final int index;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: AppDuration.micro,
              margin: const EdgeInsets.only(right: AppSpacing.x1),
              width: i == index ? 20 : 8,
              height: 4,
              decoration: BoxDecoration(
                color: i == index
                    ? tokens.colors.accent
                    : tokens.colors.border,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
      ],
    );
  }
}
