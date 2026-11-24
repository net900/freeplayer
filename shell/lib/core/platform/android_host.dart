import 'dart:io';

import 'package:flutter/services.dart';

/// Bridge to MainActivity: SAF pickers, the share/open intents, and the
/// launch intent that started the app.
///
/// Every method is a no-op on other platforms, so callers do not need their
/// own platform checks for the calls that are shared with desktop.
abstract final class AndroidHost {
  static const MethodChannel _channel = MethodChannel('free_player/android');

  static bool get _enabled => Platform.isAndroid;

  /// Intents that arrive while the app is already running (share sheet,
  /// "open with", `freeplayer://source?url=…`). The value is a local path or
  /// a `freeplayer://` link.
  static void listen(void Function(String value) onOpen) {
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOpen' && call.arguments is String) {
        final value = call.arguments as String;
        if (value.isNotEmpty) onOpen(value);
      }
      return null;
    });
  }

  /// The path or link that launched this process, if any.
  static Future<String?> initialOpen() async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<String>('initialOpen');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens the system picker and returns a folder holding the chosen videos.
  ///
  /// SAF gives the app content URIs, which libmpv cannot open directly, so
  /// MainActivity copies the selection into the app cache and hands back a
  /// real path. Multiple picks land in one folder, which the local playlist
  /// already understands as a series.
  static Future<String?> pickVideos() async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<String>('pickVideos');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> openUrl(String url) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('openUrl', {'url': url});
    } on MissingPluginException {
      // Not an Android build.
    } on PlatformException {
      // No browser, or the system refused.
    }
  }

  /// Android has no standard "open this folder" intent for app-specific
  /// storage. The caller shows the path instead.
  static Future<void> openFolder(String path) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('openFolder', {'path': path});
    } on MissingPluginException {
      // Not an Android build.
    } on PlatformException {
      // The Files app may not expose the directory.
    }
  }
}
