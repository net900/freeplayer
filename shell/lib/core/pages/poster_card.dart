import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sp/models.dart';
import '../theme/app_theme.dart';
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
  bool _focused = false;

  Future<void> _showContextMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = overlay.globalToLocal(globalPosition);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'open', child: Text('查看详情')),
        PopupMenuItem(value: 'copy', child: Text('复制标题')),
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'open') {
      widget.onTap?.call();
    } else if (selected == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.item.title));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('已复制标题')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tokens = AppTokens.of(context);
    final badges = <String>[
      if (widget.forceNewBadge) '新',
      ...item.badges,
    ];

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapUp: (details) =>
              _showContextMenu(details.globalPosition),
          // A blurred shadow animating under the pointer repaints the whole
          // card on every hover; the lift alone reads the same and is cheap.
          child: AnimatedContainer(
            duration: AppDuration.micro,
            curve: AppDuration.ease,
            transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: _focused ? tokens.colors.accent : Colors.transparent,
                width: AppSizes.focusRing,
              ),
            ),
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
