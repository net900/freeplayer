import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../logging/app_log.dart';
import 'android_host.dart';

/// Routes Android launch intents into the same pending fields the desktop
/// command line uses, so the shell handles both inputs identically.
abstract final class MobileLaunch {
  static void install(AppController controller) {
    AndroidHost.listen((value) => _route(controller, value));
    unawaited(_consumeInitial(controller));
  }

  static Future<void> _consumeInitial(AppController controller) async {
    try {
      final value = await AndroidHost.initialOpen();
      if (value == null || value.isEmpty) return;
      _route(controller, value);
    } on Object catch (error) {
      AppLog.write('android initial intent failed: $error');
    }
  }

  static void _route(AppController controller, String value) {
    debugPrint('android intent: $value');
    if (value.startsWith('freeplayer://')) {
      controller.setPendingSourceUrl(value);
      return;
    }
    controller.setPendingLocalFile(value);
    // A video shared into a fresh install must skip onboarding; the shell
    // consumes the pending path once local mode brings it on screen.
    unawaited(controller.enableLocalMode());
  }
}
