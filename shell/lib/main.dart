import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'core/local/local_media.dart';
import 'core/window/window_controls.dart';
import 'core/logging/app_log.dart';
import 'core/local/single_instance.dart';

const bool _previewFromEnv = bool.fromEnvironment('PREVIEW');

/// The website can hand a source to the app with `freeplayer://source?url=…`.
String? _sourceLink(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('freeplayer://')) return arg;
  }
  return null;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.install();
  // Keep the semantics tree published: it powers screen readers and lets UI
  // automation attach to the frameless window.
  SemanticsBinding.instance.ensureSemantics();
  // Covers decode at their display size now; cap the cache anyway so a long
  // browsing session cannot grow it without bound.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = 64 << 20;
  MediaKit.ensureInitialized();

  final launchPath = LocalMedia.firstLaunchPath(args);
  final launchSource = _sourceLink(args);
  final services = await bootstrap();

  final isPrimary = await SingleInstance.claim(
    (value) async {
      if (value.startsWith('freeplayer://')) {
        services.controller.setPendingSourceUrl(value);
      } else {
        services.controller.setPendingLocalFile(value);
      }
    },
    onActivate: WindowControls.activate,
  );
  if (!isPrimary) {
    // Never a second window: hand the link to the running instance, ask it to
    // come to the front, then leave.
    await SingleInstance.forward(launchSource ?? launchPath ?? '');
    if (await SingleInstance.isPrimaryAlive()) {
      await SingleInstance.release();
      exit(0);
    }
    // Port taken by an unrelated process: keep going as a normal window.
  }

  // Only the instance that actually runs the app checks and starts the core.
  // It is installed with the Hongguo source; startup only checks for updates.
  final coreUpdated = startCore(services);
  unawaited(coreUpdated);

  if (launchSource != null) {
    services.controller.setPendingSourceUrl(launchSource);
  } else if (launchPath != null) {
    services.controller.setPendingLocalFile(launchPath);
  }

  // Debug-only UI preview: `--preview`, or `--dart-define=PREVIEW=true`
  // when running through `flutter run`.
  if (kDebugMode && (args.contains('--preview') || _previewFromEnv)) {
    await services.controller.startPreview();
  }

  runApp(FreePlayerApp(services: services, coreUpdated: coreUpdated));
}
