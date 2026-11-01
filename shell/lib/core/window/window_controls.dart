import 'package:flutter/services.dart';

/// Bridge to the native runner. The window is frameless, so dragging,
/// minimizing, maximizing and closing are driven by the Flutter title bar.
class WindowControls {
  static const MethodChannel _channel = MethodChannel('free_player/window');

  /// Hands the drag to the OS. This is the only way to keep the window under
  /// the cursor without feedback: the pointer's local coordinates shift as the
  /// window moves, so a Flutter-driven delta loop jitters.
  static Future<void> drag() async {
    await _invoke('drag');
  }

  /// Starts a native resize from the given edge/corner.
  static Future<void> startResize(String edge) async {
    await _invoke('startResize', {'edge': edge});
  }

  static Future<void> minimize() async {
    await _invoke('minimize');
  }

  /// Brings the running window to the front (restoring it when minimised).
  /// A second launch hands its link over and asks for this instead of opening
  /// another window.
  static Future<void> activate() async {
    await _invoke('activate');
  }

  static Future<bool> toggleMaximize() async {
    try {
      return await _channel.invokeMethod<bool>('toggleMaximize') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> isMaximized() async {
    try {
      return await _channel.invokeMethod<bool>('isMaximized') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> close() async {
    await _invoke('close');
  }

  /// Borderless monitor-sized window for the player. The Flutter title bar is
  /// hidden by AppController.immersive at the same time.
  static Future<void> setFullscreen(bool on) async {
    try {
      await _channel.invokeMethod<bool>('setFullscreen', {'on': on});
    } on MissingPluginException {
      // Not running on Windows.
    } on PlatformException {
      // A rejected native call must not crash the shell.
    }
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not running on Windows (e.g. a widget test): no-op.
    } on PlatformException {
      // A rejected native call must not crash the shell.
    }
  }
}
