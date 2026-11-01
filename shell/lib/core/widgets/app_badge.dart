import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// One badge definition for the whole app: poster corners, detail metadata,
/// rank rows and the series sheet all classify labels the same way, so a 新
/// badge is green everywhere instead of every badge being brand red.
enum BadgeKind { neutral, fresh, premium, upcoming, hot, rating }

class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.onImage = false,
    this.compact = false,
  });

  final String label;

  /// On a cover the badge needs more contrast; on a surface it is tinted.
  final bool onImage;
  final bool compact;

  static BadgeKind kindOf(String raw) {
    final label = raw.trim();
    if (label.isEmpty) return BadgeKind.neutral;
    if (label.contains('预约') ||
        label.contains('待上线') ||
        label.contains('即将')) {
      return BadgeKind.upcoming;
    }
    if (label.contains('独播') ||
        label.contains('独家') ||
        label.contains('首发') ||
        label.contains('会员')) {
      return BadgeKind.premium;
    }
    if (label == '新' ||
        label == '新剧' ||
        label == '上新' ||
        label.contains('更新') ||
        label == '已上线') {
      return BadgeKind.fresh;
    }
    if (label.contains('热') || label.contains('爆') || label.contains('榜')) {
      return BadgeKind.hot;
    }
    if (label.endsWith('分') || label.contains('评分')) {
      return BadgeKind.rating;
    }
    return BadgeKind.neutral;
  }

  static Color colorOf(BadgeKind kind, AppColors colors) {
    return switch (kind) {
      BadgeKind.fresh => colors.badgeNew,
      BadgeKind.premium => colors.badgeGold,
      BadgeKind.upcoming => colors.badgeInfo,
      BadgeKind.hot => colors.badgeHot,
      BadgeKind.rating => colors.badgeGold,
      BadgeKind.neutral => colors.text2,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTokens.of(context).colors;
    final kind = kindOf(label);
    final color = colorOf(kind, colors);
    final neutral = kind == BadgeKind.neutral;

    final Color background;
    final Color foreground;
    final Color? border;
    if (onImage) {
      if (neutral) {
        background = Colors.black.withValues(alpha: 0.34);
        foreground = Colors.white;
        border = Colors.white.withValues(alpha: 0.18);
      } else {
        // Keep the cover readable through the chip: a very light wash of the
        // semantic colour, with the same colour at full strength for the
        // label. The shadow holds the edge over bright artwork.
        background = color.withValues(alpha: 0.10);
        foreground = color;
        border = color.withValues(alpha: 0.26);
      }
    } else if (neutral) {
      background = colors.surface3;
      foreground = colors.text2;
      border = null;
    } else {
      background = color.withValues(alpha: 0.14);
      foreground = color;
      border = color.withValues(alpha: 0.34);
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.x1 : AppSpacing.x2,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppFontSize.xxs,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: foreground,
          shadows: onImage
              ? const [
                  Shadow(color: Color(0x66000000), blurRadius: 4),
                ]
              : null,
        ),
      ),
    );
  }
}

/// Up to [max] badges in one row, used by poster corners and metadata rows.
class AppBadgeRow extends StatelessWidget {
  const AppBadgeRow({
    super.key,
    required this.labels,
    this.onImage = false,
    this.compact = false,
    this.max = 2,
    this.spacing = AppSpacing.x1,
  });

  final List<String> labels;
  final bool onImage;
  final bool compact;
  final int max;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final label in labels.take(max))
          AppBadge(label: label, onImage: onImage, compact: compact),
      ],
    );
  }
}
