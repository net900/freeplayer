import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/paths.dart';

/// Small rolling log next to the app data, so a user can attach a file when
/// something breaks instead of describing a black screen.
class AppLog {
  AppLog._();

  static const int _maxBytes = 2 << 20;
  static File? _file;
  static bool _installed = false;

  static void install() {
    if (_installed || !Platform.isWindows) return;
    _installed = true;
    try {
      final dir = Directory(joinPath(appDataDirectory().path, 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(joinPath(dir.path, 'app.log'));
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        // One generation is enough to debug the current session.
        final previous = File(joinPath(dir.path, 'app.1.log'));
        if (previous.existsSync()) previous.deleteSync();
        file.renameSync(previous.path);
      }
      _file = file;
    } on Object {
      _file = null;
    }
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      previousHandler?.call(details);
      write('ERROR ${details.exceptionAsString()}\n${details.stack ?? ''}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      write('UNCAUGHT $error\n$stack');
      return false;
    };
  }

  static void write(String message) {
    final file = _file;
    if (file == null) return;
    try {
      final stamp = DateTime.now().toIso8601String();
      file.writeAsStringSync('$stamp $message\n', mode: FileMode.append);
    } on Object {
      // Logging must never take the app down.
    }
  }
}
