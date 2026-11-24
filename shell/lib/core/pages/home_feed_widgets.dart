import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../gateway/source_api.dart';
import '../player/playback_engine.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'series_actions.dart';

class FeedGlassTabs extends StatelessWidget {
  const FeedGlassTabs({
    required this.tabs,
    required this.current,
    required this.onSelect,
    this.topInset = 0,
    this.leftInset = 0,
    this.refreshing = false,
  });

  final List<HomeTab> tabs;
  final HomeTab current;
  final ValueChanged<HomeTab> onSelect;

  /// Shows a spinner in place of the refresh glyph on the 推荐 tab.
  final bool refreshing;

  /// Clears the transparent window drag bar that floats over the video.
  final double topInset;

  /// Width the floating sidebar covers; the row centres in the picture to its
  /// right instead of the whole window.
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();
    final accent = AppTokens.of(context).colors.accent;
    return Positioned(
      top: 0,
      left: leftInset,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          // Sits right under the drag bar. There is no background at all;
          // the text shadow carries readability over the picture.
          padding: EdgeInsets.only(top: topInset + AppSpacing.x1),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x3,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < tabs.length; index++) ...[
                    _FeedTab(
                      label: tabs[index].title,
                      selected: tabs[index].channel == current.channel,
                      accent: accent,
                      // The first tab is 推荐; tapping it reloads the feed, so
                      // it carries the refresh affordance.
                      showRefresh: index == 0,
                      refreshing: refreshing && index == 0,
                      onTap: () => onSelect(tabs[index]),
                    ),
                    if (index < tabs.length - 1)
                      const SizedBox(width: AppSpacing.x2),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedTab extends StatefulWidget {
  const _FeedTab({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.showRefresh = false,
    this.refreshing = false,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  final bool showRefresh;
  final bool refreshing;

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? Colors.white
        : _hover
            ? Colors.white
            : Colors.white70;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x2,
            vertical: AppSpacing.x1,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedDefaultTextStyle(
                duration: AppDuration.micro,
                curve: AppDuration.ease,
                // Keep the ambient font family/fallback; a bare TextStyle
                // here used to switch the tabs to the platform typeface.
                style: DefaultTextStyle.of(context).style.copyWith(
                  fontSize: AppFontSize.bodyLg,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: color,
                  shadows: const [
                    Shadow(color: Color(0x99000000), blurRadius: 8),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.label),
                    if (widget.showRefresh) ...[
                      const SizedBox(width: 4),
                      if (widget.refreshing)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: color,
                          ),
                        )
                      else
                        Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: color.withValues(alpha: 0.8),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: AppDuration.micro,
                curve: AppDuration.ease,
                width: widget.selected ? 16 : 0,
                height: 2,
                decoration: BoxDecoration(
                  color: widget.accent,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedOverlay extends StatelessWidget {
  const FeedOverlay({
    required this.item,
    required this.stats,
    required this.onTap,
    required this.onOpenFull,
    required this.onOpenDetail,
    required this.onScrollSignal,
    this.api,
    this.episodeId = '',
    this.leftInset = 0,
  });

  final Item item;
  final ItemStats? stats;
  final VoidCallback onTap;
  final VoidCallback onOpenFull;
  final VoidCallback onOpenDetail;
  final void Function(PointerSignalEvent) onScrollSignal;
  final SourceApi? api;
  final String episodeId;

  /// Keeps the caption clear of the floating sidebar on the immersive home
  /// layout; the video itself still paints edge to edge.
  final double leftInset;

  List<String> get _meta {
    final s = stats;
    final parts = <String>[];
    if (s != null && s.seasonIndex > 0) parts.add('第${s.seasonIndex}季');
    // Current progress reads as one fact: 第1集/共886集.
    if (s != null && s.episodeIndex > 0 && s.episodeCount > 0) {
      parts.add('第${s.episodeIndex}集/共${s.episodeCount}集');
    } else if (s != null && s.episodeCount > 0) {
      parts.add('共${s.episodeCount}集');
    } else if (s != null && s.episodeIndex > 0) {
      parts.add('第${s.episodeIndex}集');
    }
    final isSeries = item.extra['is_series'] == true;
    if (isSeries) parts.add('系列剧');
    if (s != null && s.playCount > 0) {
      parts.add('${formatCount(s.playCount)}次播放');
    }
    if (s != null && s.status > 0) {
      parts.add(s.status == 1 ? '已完结' : '连载中');
    }
    return parts;
  }

  List<String> get _categories {
    final s = stats;
    if (s != null && s.categories.isNotEmpty) return s.categories;
    final raw = item.extra['categories'];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final meta = _meta;
    final categories = _categories.take(3).join(' · ');

    return Listener(
      // Registered here (below the PageView's Scrollable) so one wheel notch
      // wins the pointer-signal arena and moves exactly one video.
      onPointerSignal: onScrollSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(0, 0.2),
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xCC000000)],
                ),
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.x4 + leftInset,
            right: 96,
            // Above the watch-all strip at the bottom of the picture area.
            bottom: 88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _FeedTitle(
                  title: item.title,
                  accent: tokens.colors.accent,
                  onTap: onOpenDetail,
                ),
                if (categories.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    categories,
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.onImageAccent,
                    ),
                  ),
                ],
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.x2),
                  Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSize.body,
                      color: Colors.white70,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: leftInset,
            right: 0,
            bottom: 0,
            child: _FeedWatchAllBar(
              meta: meta.join(' · '),
              current: (stats?.episodeIndex ?? 0) > 0
                  ? stats!.episodeIndex
                  : 1,
              total: (stats?.episodeCount ?? item.episodeCount) > 0
                  ? (stats?.episodeCount ?? item.episodeCount)
                  : 0,
              accent: tokens.colors.accent,
              onTap: onOpenFull,
            ),
          ),
          if (api != null)
            Positioned(
              right: AppSpacing.x3,
              bottom: 110,
              child: SeriesActionRail(
                api: api!,
                item: item,
                episodeId: episodeId,
                stats: stats,
              ),
            ),
        ],
        ),
      ),
    );
  }
}

/// The watch-all strip along the bottom of the picture area (right of the
/// rail). It replaces the old pill: the series facts sit on the left, the
/// episode progress and the call to action on the right, over a black wash
/// that fades upward.
class _FeedWatchAllBar extends StatefulWidget {
  const _FeedWatchAllBar({
    required this.meta,
    required this.current,
    required this.total,
    required this.accent,
    required this.onTap,
  });

  final String meta;
  final int current;
  final int total;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_FeedWatchAllBar> createState() => _FeedWatchAllBarState();
}

class _FeedWatchAllBarState extends State<_FeedWatchAllBar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final label =
        total > 0 ? '点击观看全剧 ${widget.current}/$total' : '点击观看全剧';
    final ambient = DefaultTextStyle.of(context).style;
    final ctaStyle = ambient.merge(TextStyle(
      fontSize: AppFontSize.body,
      fontWeight: FontWeight.w600,
      color: _hover ? widget.accent : Colors.white,
      shadows: const [Shadow(color: Color(0x99000000), blurRadius: 6)],
    ));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDuration.micro,
          curve: AppDuration.ease,
          height: 64,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x4,
            26,
            AppSpacing.x4,
            10,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: _hover ? 0.9 : 0.76),
                Colors.black.withValues(alpha: _hover ? 0.62 : 0.46),
                Colors.transparent,
              ],
              stops: const [0, 0.46, 1],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Cap the CTA and ellipsize its label: in a narrow window the
              // fixed "点击观看全剧 1/559" ran past the right edge (53-211 px).
              final ctaMax = constraints.maxWidth * 0.6;
              return Row(
                children: [
                  if (widget.meta.isNotEmpty) ...[
                    Expanded(
                      child: Text(
                        widget.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ambient.merge(
                          const TextStyle(
                            fontSize: AppFontSize.xs,
                            color: Colors.white70,
                            shadows: [
                              Shadow(color: Color(0x99000000), blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x4),
                  ],
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: ctaMax),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_circle_fill_rounded,
                          size: 18,
                          color: widget.accent,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: AnimatedDefaultTextStyle(
                            duration: AppDuration.micro,
                            curve: AppDuration.ease,
                            style: ctaStyle,
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: _hover ? widget.accent : Colors.white70,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The feed caption. Clicking it opens the work's detail page, so it reads as
/// a link: pointer cursor plus an accent underline on hover.
class _FeedTitle extends StatefulWidget {
  const _FeedTitle({
    required this.title,
    required this.accent,
    required this.onTap,
  });

  final String title;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_FeedTitle> createState() => _FeedTitleState();
}

class _FeedTitleState extends State<_FeedTitle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(
      fontSize: AppFontSize.h2,
      fontWeight: FontWeight.w700,
      color: Colors.white,
      shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
    );
    // Keep the ambient font family/fallback: AnimatedDefaultTextStyle
    // replaces the inherited style rather than merging it.
    final style = DefaultTextStyle.of(context).style.merge(base);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedDefaultTextStyle(
          duration: AppDuration.micro,
          curve: AppDuration.ease,
          style: style.copyWith(
            decoration:
                _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: widget.accent,
            decorationThickness: 2,
          ),
          child: Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class FeedLoading extends StatelessWidget {
  const FeedLoading({this.leftInset = 0});

  /// Centres in the picture area to the right of the floating navigation.
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x33000000),
      child: Padding(
        padding: EdgeInsets.only(left: leftInset),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: AppSpacing.x2),
              Text(
                '加载中…',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: AppFontSize.xs,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown while the list fetches the page after the last card. Without it a
/// timed-out page looked exactly like the end of the feed.
class FeedMoreBadge extends StatelessWidget {
  const FeedMoreBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x66000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white70,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '正在加载下一页…',
            style: TextStyle(
              color: Colors.white70,
              fontSize: AppFontSize.xs,
            ),
          ),
        ],
      ),
    );
  }
}

class FeedPauseBadge extends StatelessWidget {
  const FeedPauseBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        color: Color(0x66000000),
        shape: BoxShape.circle,
      ),
      child:
          const Icon(Icons.play_arrow_rounded, size: 40, color: Colors.white),
    );
  }
}

class FeedError extends StatelessWidget {
  const FeedError({
    required this.message,
    required this.onRetry,
    this.leftInset = 0,
  });

  final String message;
  final VoidCallback onRetry;
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xB3000000),
      child: Padding(
        padding: EdgeInsets.only(left: leftInset),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 36,
                  color: Colors.white70,
                ),
                const SizedBox(height: AppSpacing.x3),
                Text(
                  message,
                  maxLines: 4,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: AppSpacing.x4),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text(AppStrings.retry),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FeedProgress extends StatelessWidget {
  const FeedProgress({required this.engine, required this.colors});

  final PlaybackEngine engine;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: engine.position,
      builder: (context, position, _) {
        final total = engine.snapshot.value.duration.inMilliseconds;
        final value = total <= 0
            ? 0.0
            : (position.inMilliseconds / total).clamp(0.0, 1.0);
        return SizedBox(
          height: 3,
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
          ),
        );
      },
    );
  }
}

class FeedScrollBehavior extends MaterialScrollBehavior {
  const FeedScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
