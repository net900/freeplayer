import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'core/local/local_media.dart';
import 'core/platform/mobile_launch.dart';
import 'core/platform/platform.dart';
import 'core/storage/paths.dart';
import 'core/window/window_controls.dart';
import 'core/logging/app_log.dart';
import 'core/local/single_instance.dart';

const bool _previewFromEnv = bool.fromEnvironment('PREVIEW');
// UI automation needs the semantics tree published even without a screen
// reader. Building it costs frame time, so it is opt-in for release builds.
const bool _uiAutomation = bool.fromEnvironment('FP_UI_AUTOMATION');

/// The website can hand a source to the app with `freeplayer://source?url=…`.
String? _sourceLink(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('freeplayer://')) return arg;
  }
  return null;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android has no APPDATA and its executable lives on a read-only
  // partition; the sandbox paths must exist before any store or the log.
  await initPlatformDirectories();
  AppLog.install();
  if (isMobilePlatform) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  // Detailed timing log while testing: frames that take long enough to read
  // as a stutter. Throttled so a debug session cannot flood app.log.
  if (kDebugMode) {
    var lastFrameLog = 0;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final timing in timings) {
        final total = timing.totalSpan.inMilliseconds;
        if (total < 50) continue;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastFrameLog < 250) continue;
        lastFrameLog = now;
        AppLog.write(
          'frame build=${timing.buildDuration.inMilliseconds}ms '
          'raster=${timing.rasterDuration.inMilliseconds}ms total=${total}ms',
        );
      }
    });
  }
  // Screen readers turn semantics on by themselves. Only automation (or a
  // debug run) needs it published for the whole session.
  if (kDebugMode || _uiAutomation) {
    SemanticsBinding.instance.ensureSemantics();
  }
  // Covers decode at their display size now; cap the cache anyway so a long
  // browsing session cannot grow it without bound.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = 64 << 20;

  // Android hands its launch intent (share sheet, "open with", a source
  // link) to MainActivity; the desktop keeps command-line arguments and the
  // single-instance handoff.
  final launchPath =
      isDesktopPlatform ? LocalMedia.firstLaunchPath(args) : null;
  final launchSource = isDesktopPlatform ? _sourceLink(args) : null;
  final services = await bootstrap();

  if (isDesktopPlatform) {
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
      // Never a second window: hand the link to the running instance, ask it
      // to come to the front, then leave.
      await SingleInstance.forward(launchSource ?? launchPath ?? '');
      if (await SingleInstance.isPrimaryAlive()) {
        await SingleInstance.release();
        exit(0);
      }
      // Port taken by an unrelated process: keep going as a normal window.
    }
  }

  // Only the instance that actually runs the app checks and starts the core.
  // It is installed with the Hongguo source; startup only checks for updates.
  unawaited(startCore(services));

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

  runApp(FreePlayerApp(services: services));
  if (isMobilePlatform) {
    // Installed after the first frame so the shell is already listening for
    // the pending source/file notification.
    MobileLaunch.install(services.controller);
  }
}
