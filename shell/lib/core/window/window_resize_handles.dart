import 'package:flutter/material.dart';

import 'window_controls.dart';

/// Invisible strips along the window edges. They start a native resize when
/// pressed, because the Flutter view covers the client area and would
/// otherwise receive the hit test instead of the window frame.
class WindowResizeHandles extends StatelessWidget {
  const WindowResizeHandles({super.key});

  static const double _edge = 6;
  static const double _corner = 10;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: _corner,
          bottom: _corner,
          width: _edge,
          child: _Handle(
            edge: 'left',
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
        ),
        Positioned(
          right: 0,
          top: _corner,
          bottom: _corner,
          width: _edge,
          child: _Handle(
            edge: 'right',
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
        ),
        Positioned(
          top: 0,
          left: _corner,
          right: _corner,
          height: _edge,
          child: _Handle(
            edge: 'top',
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          bottom: 0,
          left: _corner,
          right: _corner,
          height: _edge,
          child: _Handle(
            edge: 'bottom',
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: _corner,
          height: _corner,
          child: _Handle(
            edge: 'topLeft',
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          width: _corner,
          height: _corner,
          child: _Handle(
            edge: 'topRight',
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: _corner,
          height: _corner,
          child: _Handle(
            edge: 'bottomLeft',
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: _corner,
          height: _corner,
          child: _Handle(
            edge: 'bottomRight',
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
      ],
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.edge, required this.cursor});

  final String edge;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => WindowControls.startResize(edge),
        child: const SizedBox.expand(),
      ),
    );
  }
}
