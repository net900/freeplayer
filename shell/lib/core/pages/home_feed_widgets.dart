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
  });

  final List<HomeTab> tabs;
  final HomeTab current;
  final ValueChanged<HomeTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Flat translucent fill instead of a backdrop blur: the blur sat on top
    // of the playing video and had to be recomputed every frame.
    final overlay = dark
        ? Colors.black.withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.84);
    final border = dark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.10);
    final selectedFill = dark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.08);
    final selectedText = dark ? Colors.white : Colors.black87;
    final unselectedText = dark ? Colors.white70 : Colors.black54;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.x2),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x2,
                vertical: AppSpacing.x1,
              ),
              decoration: BoxDecoration(
                color: overlay,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tab in tabs)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(tab),
                      child: AnimatedContainer(
                        duration: AppDuration.micro,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.x4,
                          vertical: AppSpacing.x1,
                        ),
                        decoration: BoxDecoration(
                          color: tab.channel == current.channel
                              ? selectedFill
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          tab.title,
                          style: TextStyle(
                            fontSize: AppFontSize.bodyLg,
                            fontWeight: tab.channel == current.channel
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: tab.channel == current.channel
                                ? selectedText
                                : unselectedText,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
    required this.onScrollSignal,
    this.api,
    this.episodeId = '',
    this.labels = const {},
  });

  final Item item;
  final ItemStats? stats;
  final VoidCallback onTap;
  final VoidCallback onOpenFull;
  final void Function(PointerSignalEvent) onScrollSignal;
  final SourceApi? api;
  final String episodeId;

  /// Source-supplied copy; empty means the shell shows a neutral label.
  final Map<String, String> labels;

  String get _playLabel {
    final count = stats?.episodeCount ?? item.episodeCount;
    final template = labels['play_full'] ?? '';
    if (template.isNotEmpty && count > 0) {
      return template.replaceAll('{count}', '$count');
    }
    final fallback = labels['play'] ?? '';
    return fallback.isEmpty ? AppStrings.play : fallback;
  }

  List<String> get _meta {
    final s = stats;
    final parts = <String>[];
    if (s != null && s.seasonIndex > 0) parts.add('第${s.seasonIndex}季');
    if (s != null && s.episodeCount > 0) parts.add('全${s.episodeCount}集');
    if (s != null && s.episodeIndex > 0) parts.add('第${s.episodeIndex}集');
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
            left: AppSpacing.x4,
            right: 96,
            bottom: AppSpacing.x6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
                  ),
                ),
                if (categories.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    categories,
                    style: const TextStyle(
                      fontSize: AppFontSize.xs,
                      color: Color(0xFFFFD8A8),
                    ),
                  ),
                ],
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    meta.join(' · '),
                    style: const TextStyle(
                      fontSize: AppFontSize.xs,
                      color: Colors.white70,
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
                const SizedBox(height: AppSpacing.x4),
                FeedFullButton(
                  label: _playLabel,
                  onTap: onOpenFull,
                  accent: tokens.colors.accent,
                ),
              ],
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

class FeedFullButton extends StatelessWidget {
  const FeedFullButton({
    required this.label,
    required this.onTap,
    required this.accent,
  });

  final String label;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
        ),
        // Scales the whole pill down when the feed column is very narrow
        // instead of overflowing the layout.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_fill_rounded, size: 20, color: accent),
              const SizedBox(width: AppSpacing.x2),
              Text(
                label,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: AppFontSize.body,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedLoading extends StatelessWidget {
  const FeedLoading();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x33000000),
      child: Center(
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
              style: TextStyle(color: Colors.white70, fontSize: AppFontSize.xs),
            ),
          ],
        ),
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
  const FeedError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xB3000000),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36, color: Colors.white70),
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
    );
  }
}

class FeedProgress extends StatelessWidget {
  const FeedProgress({required this.engine, required this.colors});

  final PlaybackEngine engine;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: engine.snapshot,
      builder: (context, snapshot, _) {
        final total = snapshot.duration.inMilliseconds;
        final value = total <= 0
            ? 0.0
            : (snapshot.position.inMilliseconds / total).clamp(0.0, 1.0);
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
