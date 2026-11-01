import 'package:flutter/material.dart';

import '../sp/models.dart';
import '../theme/tokens.dart';
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';

/// Poster tile: cover, title and badges. When a source returns no cover the
/// shell draws a deterministic gradient instead of a broken image.
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.item,
    this.onTap,
    this.forceNewBadge = false,
  });

  final Item item;
  final VoidCallback? onTap;
  final bool forceNewBadge;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final badges = <String>[
      if (widget.forceNewBadge) '新',
      ...item.badges,
    ];

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // A blurred shadow animating under the pointer repaints the whole
        // card on every hover; the lift alone reads the same and is cheap.
        child: AnimatedContainer(
          duration: AppDuration.micro,
          curve: AppDuration.ease,
          transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _cover(context, item),
                const _Scrim(),
                Positioned(
                  left: AppSpacing.x2,
                  right: AppSpacing.x2,
                  bottom: AppSpacing.x2,
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      shadows: const [
                        Shadow(color: Color(0x99000000), blurRadius: 6),
                      ],
                    ),
                  ),
                ),
                if (badges.isNotEmpty)
                  Positioned(
                    left: AppSpacing.x2,
                    top: AppSpacing.x2,
                    right: AppSpacing.x2,
                    child: AppBadgeRow(
                      labels: badges,
                      onImage: true,
                      compact: true,
                      max: 2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(BuildContext context, Item item) {
    return CoverImage(url: item.cover, seed: item.title);
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.center,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xCC000000)],
        ),
      ),
    );
  }
}
