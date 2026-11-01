import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../theme/tokens.dart';
import 'window_controls.dart';

/// Custom title bar for the frameless window. The drag region is empty space;
/// the three buttons are the only interactive parts on the right.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({
    super.key,
    required this.colors,
    required this.themeMode,
    required this.onCycleTheme,
  });

  final AppColors colors;
  final ThemeMode themeMode;
  final VoidCallback onCycleTheme;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> {
  bool _maximized = false;
  String? _hoveredButton;
  Offset? _downPosition;
  bool _dragStarted = false;
  DateTime? _lastClickAt;

  @override
  void initState() {
    super.initState();
    WindowControls.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  Future<void> _toggleMaximize() async {
    final maximized = await WindowControls.toggleMaximize();
    if (mounted) setState(() => _maximized = maximized);
  }

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _dragStarted = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragStarted || _downPosition == null) return;
    if ((event.position - _downPosition!).distance < 4) return;
    _dragStarted = true;
    WindowControls.drag();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_dragStarted) {
      final now = DateTime.now();
      final last = _lastClickAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 350)) {
        _lastClickAt = null;
        _toggleMaximize();
      } else {
        _lastClickAt = now;
      }
    }
    _dragStarted = false;
    _downPosition = null;
  }

  void _setHovered(String id, bool hovered) {
    setState(() {
      if (hovered) {
        _hoveredButton = id;
      } else if (_hoveredButton == id) {
        _hoveredButton = null;
      }
    });
  }

  IconData _themeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: TextStyle(fontSize: 11, color: colors.text2),
        child: AnimatedContainer(
          duration: AppDuration.page,
          curve: AppDuration.ease,
          height: 36,
          color: colors.surface,
          child: Row(
            children: [
              const SizedBox(width: AppSpacing.x3),
              Icon(Icons.play_circle_fill, size: 14, color: colors.accent),
              const SizedBox(width: AppSpacing.x2),
              Text(
                AppStrings.appName,
                style: TextStyle(fontSize: 11, color: colors.text2),
              ),
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: (_) {
                    _dragStarted = false;
                    _downPosition = null;
                  },
                  child: const SizedBox.expand(),
                ),
              ),
              _WindowButton(
                id: 'theme',
                icon: _themeIcon(widget.themeMode),
                semanticLabel: AppStrings.theme,
                width: 40,
                colors: colors,
                hovered: _hoveredButton == 'theme',
                onHover: _setHovered,
                onTap: () async => widget.onCycleTheme(),
              ),
              Container(
                width: 1,
                height: 16,
                margin: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x1,
                ),
                color: colors.border,
              ),
              _WindowButton(
                id: 'min',
                icon: Icons.remove,
                semanticLabel: AppStrings.windowMinimize,
                colors: colors,
                hovered: _hoveredButton == 'min',
                onHover: _setHovered,
                onTap: WindowControls.minimize,
              ),
              _WindowButton(
                id: 'max',
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                semanticLabel: _maximized
                    ? AppStrings.windowRestore
                    : AppStrings.windowMaximize,
                colors: colors,
                hovered: _hoveredButton == 'max',
                onHover: _setHovered,
                onTap: _toggleMaximize,
              ),
              _WindowButton(
                id: 'close',
                icon: Icons.close,
                semanticLabel: AppStrings.windowClose,
                colors: colors,
                danger: true,
                hovered: _hoveredButton == 'close',
                onHover: _setHovered,
                onTap: WindowControls.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.id,
    required this.icon,
    required this.semanticLabel,
    required this.colors,
    required this.hovered,
    required this.onHover,
    required this.onTap,
    this.width = 46,
    this.danger = false,
  });

  final String id;
  final IconData icon;
  final String semanticLabel;
  final AppColors colors;
  final bool hovered;
  final void Function(String id, bool hovered) onHover;
  final Future<void> Function() onTap;
  final double width;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final background = hovered
        ? (danger ? colors.danger : colors.surface3)
        : Colors.transparent;
    final foreground = hovered && danger ? Colors.white : colors.text2;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(id, true),
        onExit: (_) => onHover(id, false),
        child: GestureDetector(
          onTap: () => onTap(),
          child: Container(
            width: width,
            height: 36,
            color: background,
            alignment: Alignment.center,
            child: Icon(icon, size: 14, color: foreground),
          ),
        ),
      ),
    );
  }
}
