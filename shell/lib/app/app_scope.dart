import 'package:flutter/widgets.dart';

import '../core/decryptor/decryptor_registry.dart';
import '../core/downloads/download_manager.dart';
import '../core/library/local_library.dart';
import '../core/local/file_association.dart';
import '../core/local_source/local_sources_service.dart';
import '../core/renderer/page_registry.dart';
import 'app_controller.dart';
import 'app_navigator.dart';
import 'local_playlist_state.dart';
import 'local_window_mode.dart';

/// Services available to every widget: controller, local library, page
/// registry and platform helpers.
///
/// This is intentionally a plain [InheritedWidget]: listening to the
/// controller is explicit (`ListenableBuilder`) so unrelated pages are not
/// rebuilt on every controller notification.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.controller,
    required this.library,
    required this.pageRegistry,
    required this.fileAssociation,
    required this.decryptorRegistry,
    required this.downloads,
    required this.navigator,
    required this.localPlaylist,
    required this.windowMode,
    required this.localSources,
    required super.child,
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
  final LocalSourcesService localSources;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing from the widget tree');
    return scope!;
  }

  static AppController controllerOf(BuildContext context) =>
      of(context).controller;

  @override
  bool updateShouldNotify(covariant AppScope oldWidget) {
    return controller != oldWidget.controller ||
        library != oldWidget.library ||
        pageRegistry != oldWidget.pageRegistry ||
        fileAssociation != oldWidget.fileAssociation ||
        decryptorRegistry != oldWidget.decryptorRegistry ||
        downloads != oldWidget.downloads ||
        navigator != oldWidget.navigator ||
        localPlaylist != oldWidget.localPlaylist ||
        windowMode != oldWidget.windowMode ||
        localSources != oldWidget.localSources;
  }
}
