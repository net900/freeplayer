import 'dart:async';
import 'dart:io';

import '../core/decryptor/decryptor_registry.dart';
import '../core/downloads/download_manager.dart';
import '../core/gateway/core_download.dart';
import '../core/gateway/local_core.dart';
import '../core/library/local_library.dart';
import '../core/local_source/local_sources_service.dart';
import '../core/local/file_association.dart';
import '../core/local/url_scheme.dart';
import '../core/pages/page_builders.dart';
import '../core/renderer/page_registry.dart';
import '../core/settings/settings_store.dart';
import '../core/storage/local_store.dart';
import '../core/storage/paths.dart';
import '../core/gateway/gateway_store.dart';
import 'app_config.dart';
import 'app_controller.dart';
import 'app_navigator.dart';
import 'local_playlist_state.dart';
import 'local_window_mode.dart';

class AppServices {
  const AppServices({
    required this.controller,
    required this.library,
    required this.pageRegistry,
    required this.fileAssociation,
    required this.decryptorRegistry,
    required this.downloads,
    required this.navigator,
    required this.localPlaylist,
    required this.windowMode,
    required this.localCore,
    required this.localSources,
  });

  final AppController controller;
  final LocalLibrary library;
  final PageRegistry pageRegistry;
  final FileAssociationService fileAssociation;
  final DecryptorRegistry decryptorRegistry;
  final DownloadManager downloads;
  final AppNavigator navigator;
  final LocalPlaylistState localPlaylist;
  final LocalWindowMode windowMode;
  final LocalCore localCore;
  final LocalSourcesService localSources;
}

Future<AppServices> bootstrap() async {
  // Before anything loads a DLL, finish deletions left by a source removed
  // while its module was still mapped in the previous session.
  final decryptorRegistry = DecryptorRegistry();
  await decryptorRegistry.cleanupPendingRemoval();
  await CoreDownload().cleanupPendingRemoval();
  final controller = AppController(
    settingsStore: SettingsStore.createDefault(),
    gatewayStore: GatewayStore(LocalStore(appDataFile('gateways.json'))),
    decryptors: decryptorRegistry,
  );
  await controller.init();
  final library = LocalLibrary(LocalStore(appDataFile('library.json')));
  final downloads = DownloadManager(
    library: library,
    settings: () => controller.settings,
  );
  unawaited(downloads.load());
  final localPlaylist = LocalPlaylistState(
    store: LocalStore(appDataFile('playlist.json')),
  );
  await localPlaylist.load();
  final localCore = LocalCore();
  final localSources = LocalSourcesService(
    LocalStore(appDataFile('local_sources.json')),
  );
  await localSources.load();
  final services = AppServices(
    controller: controller,
    library: library,
    pageRegistry: buildPageRegistry(),
    fileAssociation: FileAssociationService(),
    decryptorRegistry: decryptorRegistry,
    downloads: downloads,
    navigator: AppNavigator(),
    localPlaylist: localPlaylist,
    windowMode: LocalWindowMode(),
    localCore: localCore,
    localSources: localSources,
  );
  await localSources.restore(controller);
  controller.setCoreInstaller(() => installSourceCore(services));
  controller.setCoreRemover(() => removeSourceCore(services));
  // Lets the website hand a source to the app with one click.
  unawaited(registerSourceUrlScheme());
  return services;
}

/// Downloads the source core when the Hongguo source is installed. Called
/// from `addGateway`, so the download belongs to the install action instead
/// of every launch.
Future<bool> installSourceCore(AppServices services) async {
  if (!Platform.isWindows) return false;
  final controller = services.controller;
  final installed = LocalCore.findLibrary();
  if (installed != null) {
    // Re-adding the source cancels a pending deletion from the previous
    // removal while the DLL was still loaded.
    try {
      final marker = File('$installed.remove');
      if (marker.existsSync()) marker.deleteSync();
    } on Object {
      // Best effort.
    }
  }
  final showProgress = installed == null;
  if (showProgress) controller.setCorePending(true);
  // One progress update per 200 ms: each notification rebuilds the shell.
  var lastReportMs = 0;
  try {
    await CoreDownload().ensure(
      onProgress: showProgress
          ? (received, total) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now - lastReportMs < 200) return;
              lastReportMs = now;
              controller.setCoreDownload(
                CoreDownloadState(received: received, total: total),
              );
            }
          : null,
    );
  } finally {
    if (showProgress) {
      controller.setCorePending(false);
      controller.setCoreDownload(null);
    }
  }
  if (LocalCore.findLibrary() == null) return false;
  final url = await services.localCore.start();
  if (url == null) return false;
  await controller.attachLocalCore(url);
  return true;
}

/// Removes the core DLL with its source. The in-process library cannot be
/// unloaded, so a locked file is retried on the next launch.
Future<void> removeSourceCore(AppServices services) async {
  services.localCore.stop();
  await CoreDownload().removeInstalled();
}

/// Startup path for the core, when its Hongguo source is present.
///
/// The DLL lives next to the executable, so it does not survive a move to a
/// new install folder while the source does — the source would then point at
/// a loopback address nothing is listening on. That case downloads the core
/// again; an installed DLL is only compared by SHA-256 and replaced when the
/// announced build differs, so a normal launch never downloads it.
///
/// Returns true when the DLL on disk was replaced, so the caller can tell the
/// user a restart picks it up.
Future<bool> startCore(AppServices services) async {
  if (!Platform.isWindows) return false;
  final hasHongguo = services.controller.enabledSources
      .any((s) => s.sourceId == coreSourceId);
  if (!hasHongguo) return false;
  if (LocalCore.findLibrary() == null) {
    // Recovery, not a routine download: the source is installed but its core
    // is gone. Progress is shown because this is ~10 MB.
    await installSourceCore(services);
    return false;
  }
  var replaced = false;
  try {
    await CoreDownload().ensure(onReplaced: () => replaced = true);
    if (LocalCore.findLibrary() == null) return replaced;
    final url = await services.localCore.start();
    if (url != null) await services.controller.attachLocalCore(url);
  } on Object {
    // A failed check must never keep the app from opening.
  }
  return replaced;
}
