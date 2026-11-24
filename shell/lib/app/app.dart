import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/local/local_media.dart';
import '../core/local/single_instance.dart';
import '../core/local_source/local_source_updates.dart';
import '../core/logging/app_log.dart';
import '../core/pages/route.dart';
import '../core/platform/platform.dart';
import '../core/player/playback_coordinator.dart';
import '../core/pages/page_title.dart';
import '../core/update/update_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../core/window/window_resize_handles.dart';
import '../core/window/window_title_bar.dart';
import '../features/firstrun/first_run_page.dart';
import '../features/shell/shell_page.dart';
import '../features/source/source_page.dart';
import '../features/source/source_switcher_button.dart';
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

class _FreePlayerAppState extends State<FreePlayerApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final PageTitleController _pageTitle = PageTitleController();
  Color? _themeSeed;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  bool _dragging = false;
  // Guards against stacking a second source page from the title-bar switcher.
  bool _sourcesOpen = false;
  // Full-screen pages pushed on the root navigator (source page, player)
  // need the opaque title bar and a reserved strip so their own back
  // controls stay clickable.
  late final _RootPageObserver _rootObserver =
      _RootPageObserver(_onRootRoutesChanged);
  int _rootBaseline = 0;
  bool _rootBaselineReady = false;

  bool _restartScheduled = false;
  // The app shell only cares about a few controller fields. Listening to the
  // whole ChangeNotifier rebuilt the entire MaterialApp on every settings
  // save, including the volume debounce during playback.
  Object? _lastUiState;

  AppController get _controller => widget.services.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastUiState = _uiStateOf(_controller);
    _scheduleUpdateCheck();
    _checkLocalSourceUpdates();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _rootBaseline = _rootObserver.pageRoutes;
        _rootBaselineReady = true;
      });
    });
  }

  void _onRootRoutesChanged() {
    if (!mounted || !_rootBaselineReady) return;
    setState(() {});
  }

  static Object _uiStateOf(AppController controller) => (
        controller.themeSeed,
        controller.settings.themeMode,
        controller.immersive,
        controller.updatingSources.join('|'),
        controller.updateProgress?.received ?? -1,
        controller.updateProgress?.total ?? -1,
        controller.restartingSoon,
      );

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
    final controller = _controller;
    final state = _uiStateOf(controller);
    if (state != _lastUiState) {
      _lastUiState = state;
      if (mounted) setState(() {});
    }
    if (_restartScheduled || !controller.restartingSoon) return;
    _restartScheduled = true;
    // Let the "更新完成" frame reach the screen first.
    Timer(
      const Duration(milliseconds: 1200),
      isMobilePlatform ? _applyUpdatesInPlace : _restartApp,
    );
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

  /// Android cannot exec a fresh copy of itself. The package files were
  /// replaced in the shared data directory, so re-reading them and rebuilding
  /// the active source gives the same fresh state without leaving the app.
  Future<void> _applyUpdatesInPlace() async {
    final controller = _controller;
    try {
      await widget.services.localSources.restore(controller);
      await controller.reloadActiveSource();
    } on Object catch (error) {
      AppLog.write('in-place update reload failed: $error');
    } finally {
      controller.clearRestarting();
      _restartScheduled = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Android turns the app into a background task while the window stays
  /// alive. Keep the video from continuing behind another app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isMobilePlatform) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(PlaybackCoordinator.instance.pauseAll());
    }
  }

  /// Silent once-per-launch check, per `update_server/docs/CLIENT_UPDATE.md`:
  /// a failure is never shown, and a dismissed build is not prompted again.
  Future<void> _scheduleUpdateCheck() async {
    // The update service packages Windows installers; an Android build is
    // installed from the website instead.
    if (isMobilePlatform) return;
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
      child: Builder(
        builder: (context) {
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
          // Chrome floating over the home video always uses the dark set so
          // its text and window buttons stay readable on any frame.
          final darkChromeColors = seed == null
              ? AppColors.dark
              : AppColors.dark.copyWith(
                  accent: readableAccent(seed: seed, brightness: Brightness.dark),
                );

          return MaterialApp(
            title: AppStrings.appName,
            navigatorKey: _navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: controller.settings.themeMode,
            navigatorObservers: [_rootObserver],
            // Instant theme swap: animating every colour in a debug build
            // drops frames and is perceived as lag.
            themeAnimationDuration: Duration.zero,
            builder: (context, child) {
              return PageTitleScope(
                controller: _pageTitle,
                child: AnimatedBuilder(
                  animation: Listenable.merge(
                    [_pageTitle.overMedia, _pageTitle.overVideo],
                  ),
                  builder: (context, _) {
                    final overMedia = _pageTitle.overMedia.value;
                    final overVideo = _pageTitle.overVideo.value;
                    // The bar floats over every page now, so pages run to the
                    // top edge. Only a full-screen page changes the bar: it
                    // gives up its brand strip for the page's back button.
                    final rootPageOpen =
                        _rootObserver.pageRoutes > _rootBaseline;
                    final chromeVisible = !controller.immersive;
                    // The home feed hands its state down through overMedia, but
                    // that still describes the page *under* a pushed route; a
                    // full-window player reports itself instead.
                    final overFeed = overMedia && !rootPageOpen;
                    final darkBar =
                        chromeVisible && (overVideo || overFeed);
                    // The status bar follows the surface under it: light icons
                    // over the player, theme-coloured icons elsewhere. The
                    // mobile home feed has an opaque top bar, so it follows the
                    // theme rather than the video underneath.
                    final onVideo = isMobilePlatform ? overVideo : darkBar;
                    final overlayStyle =
                        (onVideo || brightness == Brightness.dark)
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark;
                    return AnnotatedRegion<SystemUiOverlayStyle>(
                      value: overlayStyle.copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor: Colors.transparent,
                        systemNavigationBarDividerColor: Colors.transparent,
                      ),
                      child: Stack(
                      children: [
                        Positioned.fill(
                          child: DropTarget(
                            onEnter: (_) =>
                                setState(() => _dragging = true),
                            onLeave: () =>
                                setState(() => _dragging = false),
                            onDrop: _onDrop,
                            child: child ?? const SizedBox.shrink(),
                          ),
                        ),
                        if (darkBar && isDesktopPlatform)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: SizedBox(
                                height: 84,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: 0.55),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (!controller.immersive && isDesktopPlatform)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: WindowTitleBar(
                              colors: darkBar
                                  ? darkChromeColors
                                  : chromeColors,
                              transparent: true,
                              showBrand: !rootPageOpen,
                              themeMode: controller.settings.themeMode,
                              onCycleTheme: () =>
                                  _cycleTheme(controller),
                              sourceSwitcher: SourceSwitcherButton(
                                colors: darkBar
                                    ? darkChromeColors
                                    : chromeColors,
                                onOpen: _openSources,
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
                    // Over video the frameless window still needs an edge, and
                    // a theme-coloured one flashed white during page fades. A
                    // dark hairline only while the chrome is over media; light
                    // pages run edge to edge with no outline at all.
                    if (!controller.immersive && darkBar && isDesktopPlatform)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.fromBorderSide(
                                BorderSide(color: Color(0x66000000)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!controller.immersive && isDesktopPlatform)
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
                ),
              );
            },
            home: const _HomeSwitch(),
          );
        },
      ),
    );
  }

  /// Opens the source manager from the title-bar switcher. The page covers
  /// the window; the title bar stays above it, so re-entry is guarded.
  Future<void> _openSources() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || _sourcesOpen) return;
    _sourcesOpen = true;
    unawaited(PlaybackCoordinator.instance.pauseAll());
    try {
      await navigator.push(
        instantRoute((_) => const SourcePage()),
      );
    } finally {
      _sourcesOpen = false;
    }
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
/// Counts full-screen page routes on the root navigator. Dialogs and bottom
/// sheets are popup routes and deliberately ignored: they must not turn the
/// window chrome opaque.
class _RootPageObserver extends NavigatorObserver {
  _RootPageObserver(this.onChanged);

  final VoidCallback onChanged;
  int pageRoutes = 0;

  void _dec() {
    if (pageRoutes > 0) pageRoutes--;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      pageRoutes++;
      onChanged();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      _dec();
      onChanged();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      _dec();
      onChanged();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PageRoute) _dec();
    if (newRoute is PageRoute) pageRoutes++;
    onChanged();
  }
}

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
