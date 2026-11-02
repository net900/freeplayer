import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../core/local/local_media.dart';
import '../core/local/single_instance.dart';
import '../core/local_source/local_source_updates.dart';
import '../core/logging/app_log.dart';
import '../core/pages/page_title.dart';
import '../core/update/update_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../core/window/window_resize_handles.dart';
import '../core/window/window_title_bar.dart';
import '../features/firstrun/first_run_page.dart';
import '../features/shell/shell_page.dart';
import '../features/update/source_update_overlay.dart';
import '../features/update/update_dialog.dart';
import '../l10n/strings.dart';
import 'app_controller.dart';
import 'app_scope.dart';
import 'bootstrap.dart';

class FreePlayerApp extends StatefulWidget {
  const FreePlayerApp({super.key, required this.services});

  final AppServices services;

  @override
  State<FreePlayerApp> createState() => _FreePlayerAppState();
}

class _FreePlayerAppState extends State<FreePlayerApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final PageTitleController _pageTitle = PageTitleController();
  Color? _themeSeed;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  bool _dragging = false;

  bool _restartScheduled = false;

  AppController get _controller => widget.services.controller;

  @override
  void initState() {
    super.initState();
    _scheduleUpdateCheck();
    _checkLocalSourceUpdates();
    _controller.addListener(_onControllerChanged);
  }

  /// Launch pass over installed local JS sources: every package is fetched
  /// again from the address it came from and compared by SHA-256, so a remote
  /// rebuild is picked up even without a version bump. The controller shows
  /// the replacement and restarts the app when the pass is over. Remote URL
  /// sources need no check here — their manifest and decryptor modules are
  /// refreshed on every launch by AppController.refreshUi.
  Future<void> _checkLocalSourceUpdates() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await autoUpdateLocalSources(
      localSources: widget.services.localSources,
      controller: _controller,
    );
  }

  /// A replacement finished. The pages and the player keep the build they
  /// loaded, so the only honest state to keep running is a fresh process.
  void _onControllerChanged() {
    if (_restartScheduled || !_controller.restartingSoon) return;
    _restartScheduled = true;
    // Let the "更新完成" frame reach the screen first.
    Timer(const Duration(milliseconds: 1200), _restartApp);
  }

  Future<void> _restartApp() async {
    try {
      // Hand over the single-instance lock before the new process starts.
      await SingleInstance.release();
      await Process.start(
        Platform.resolvedExecutable,
        const [],
        mode: ProcessStartMode.detached,
      );
    } on Object catch (error) {
      AppLog.write('restart after update failed: $error');
      return;
    }
    exit(0);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Silent once-per-launch check, per `update_server/docs/CLIENT_UPDATE.md`:
  /// a failure is never shown, and a dismissed build is not prompted again.
  Future<void> _scheduleUpdateCheck() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final controller = widget.services.controller;
    final result = await UpdateService.check(
      declinedKey: controller.settings.updateDeclinedKey,
    );
    final info = result.info;
    if (info == null || !mounted) return;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    await showUpdateDialog(context, info, onDecline: () {
      controller.updateSettings(
        controller.settings.copyWith(updateDeclinedKey: info.declineKey),
      );
    });
  }

  /// Dropping a file or folder works on every page: the target wraps the
  /// whole window, not just the shell underneath an open player.
  Future<void> _onDrop(DropDetails details) async {
    if (!mounted) return;
    setState(() => _dragging = false);
    final paths = <String>[];
    for (final item in details.items) {
      String? path;
      if (item is DropFileItem) path = item.localPath;
      if (item is DropDirectoryItem) path = item.localPath;
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    final videos = LocalMedia.collectVideos(paths);
    if (videos.isEmpty) return;
    final controller = widget.services.controller;
    if (!controller.localMode) {
      await controller.enableLocalMode();
    }
    // Pass the dropped path itself (a directory stays a directory) so the
    // shell can build the folder playlist; the shell decides between
    // whole-window and sidebar playback from the setting.
    controller.setPendingLocalFile(paths.isNotEmpty ? paths.first : videos.first);
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final controller = services.controller;
    return AppScope(
      controller: controller,
      library: services.library,
      pageRegistry: services.pageRegistry,
      fileAssociation: services.fileAssociation,
      decryptorRegistry: services.decryptorRegistry,
      downloads: services.downloads,
      navigator: services.navigator,
      localPlaylist: services.localPlaylist,
      windowMode: services.windowMode,
      localSources: services.localSources,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final seed = controller.themeSeed;
          if (_lightTheme == null || seed != _themeSeed) {
            _themeSeed = seed;
            _lightTheme =
                buildAppTheme(brightness: Brightness.light, seed: seed);
            _darkTheme = buildAppTheme(brightness: Brightness.dark, seed: seed);
          }

          final brightness = switch (controller.settings.themeMode) {
            ThemeMode.light => Brightness.light,
            ThemeMode.dark => Brightness.dark,
            ThemeMode.system =>
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
          };
          final baseColors =
              brightness == Brightness.dark ? AppColors.dark : AppColors.light;
          final chromeColors = seed == null
              ? baseColors
              : baseColors.copyWith(
                  accent: readableAccent(seed: seed, brightness: brightness),
                );

          return MaterialApp(
            title: AppStrings.appName,
            navigatorKey: _navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: controller.settings.themeMode,
            // Instant theme swap: animating every colour in a debug build
            // drops frames and is perceived as lag.
            themeAnimationDuration: Duration.zero,
            builder: (context, child) {
              return PageTitleScope(
                controller: _pageTitle,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DropTarget(
                        onEnter: (_) => setState(() => _dragging = true),
                        onLeave: () => setState(() => _dragging = false),
                        onDrop: _onDrop,
                        child: Column(
                          children: [
                            if (!controller.immersive)
                              WindowTitleBar(
                                colors: chromeColors,
                                themeMode: controller.settings.themeMode,
                                onCycleTheme: () => _cycleTheme(controller),
                              ),
                            Expanded(child: child ?? const SizedBox.shrink()),
                          ],
                        ),
                      ),
                    ),
                    if (_dragging)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            color: const Color(0xCC000000),
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 48,
                                vertical: 32,
                              ),
                              decoration: BoxDecoration(
                                color: chromeColors.surface,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.lg),
                                border: Border.all(
                                  color: chromeColors.accent,
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.video_file_outlined,
                                    size: 52,
                                    color: chromeColors.accent,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    '松开播放本地视频',
                                    style: TextStyle(
                                      color: chromeColors.text,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '拖入视频直接播放；拖入文件夹按文件名顺序连播',
                                    style: TextStyle(
                                      color: chromeColors.text3,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!controller.immersive)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            // The frameless window has no OS edge; keep a 1px
                            // outline so the boundary stays visible at any
                            // manually resized size.
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: chromeColors.border,
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!controller.immersive)
                      const Positioned.fill(child: WindowResizeHandles()),
                    if (controller.updatingSources.isNotEmpty ||
                        controller.restartingSoon)
                      SourceUpdateOverlay(
                        names: controller.updatingSources,
                        progress: controller.updateProgress,
                        restarting: controller.restartingSoon,
                      ),
                  ],
                ),
              );
            },
            home: const _HomeSwitch(),
          );
        },
      ),
    );
  }

  void _cycleTheme(AppController controller) {
    final current = controller.settings.themeMode;
    final next = current == ThemeMode.system
        ? ThemeMode.light
        : current == ThemeMode.light
            ? ThemeMode.dark
            : ThemeMode.system;
    controller.updateSettings(controller.settings.copyWith(themeMode: next));
  }
}

/// Keeps the navigator's home route stable while the visible screen follows
/// onboarding / preview state, so leaving preview actually swaps the page
/// instead of leaving the cached first route on screen.
class _HomeSwitch extends StatelessWidget {
  const _HomeSwitch();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controllerOf(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          controller.needsOnboarding ? const FirstRunPage() : const ShellPage(),
    );
  }
}
