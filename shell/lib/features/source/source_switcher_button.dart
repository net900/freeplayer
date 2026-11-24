import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/tokens.dart';

/// Transparent source selector for the window title bar, placed left of the
/// theme toggle. It draws no surface of its own: the title bar behind it is
/// the only background, so it stays readable over the immersive home video.
class SourceSwitcherButton extends StatefulWidget {
  const SourceSwitcherButton({
    super.key,
    required this.colors,
    required this.onOpen,
  });

  /// Chrome colours the title bar is currently using (dark while it floats
  /// over the home video, theme colours otherwise).
  final AppColors colors;

  /// Opens the source page. Preview mode is handled inside this widget.
  final VoidCallback onOpen;

  @override
  State<SourceSwitcherButton> createState() => _SourceSwitcherButtonState();
}

class _SourceSwitcherButtonState extends State<SourceSwitcherButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controllerOf(context);
    // The title bar lives above the shell, so it has to listen to the
    // controller itself for source/preview changes.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preview = controller.isPreview;
        final name = controller.activeSourceName;
        final textColor = _hover ? widget.colors.text : widget.colors.text2;
        // No Tooltip here: the title bar sits above the Navigator and has no
        // Overlay ancestor for a tooltip popup. The label itself plus the
        // semantics label carry the meaning.
        return Semantics(
          button: true,
          label: preview ? '退出预览' : '切换源',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (preview) {
                  controller.exitPreview();
                } else {
                  widget.onOpen();
                }
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2,
                    vertical: AppSpacing.x1,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_fill,
                        size: 14,
                        color: widget.colors.accent,
                      ),
                      const SizedBox(width: AppSpacing.x1 + 2),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppFontSize.xs,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                            shadows: const [
                              Shadow(color: Color(0x99000000), blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                      if (!preview) ...[
                        const SizedBox(width: 2),
                        Icon(
                          Icons.expand_more,
                          size: 16,
                          color: widget.colors.text3,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
