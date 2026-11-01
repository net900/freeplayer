import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../core/local/local_media.dart';
import '../core/local_source/local_source_updates.dart';
import '../core/pages/page_title.dart';
import '../core/update/update_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../core/window/window_resize_handles.dart';
import '../core/window/window_title_bar.dart';
import '../features/firstrun/first_run_page.dart';
import '../features/shell/shell_page.dart';
import '../features/update/update_dialog.dart';
import '../l10n/strings.dart';
import 'app_controller.dart';
import 'app_scope.dart';
import 'bootstrap.dart';

class FreePlayerApp extends StatefulWidget {
  const FreePlayerApp({
    super.key,
    required this.services,
    this.coreUpdated,
  });

  final AppServices services;

  /// Completes once the launch-time core check is done; true when the DLL was
  /// replaced. The app is already on screen by then, so this is how the
  /// restart notice reaches it.
  final Future<bool>? coreUpdated;

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

  @override
  void initState() {
    super.initState();
    _scheduleUpdateCheck();
    _checkLocalSourceUpdates();
    widget.coreUpdated?.then((updated) {
      if (updated) _notifyRestart(const ['资源核心']);
    });
  }

  /// Silent pass over installed local JS sources: every package is fetched
  /// again from the address it came from and compared by SHA-256, so a remote
  /// rebuild is installed without asking. Remote URL sources need no check
  /// here — their manifest and decryptor modules are refreshed on every launch
  /// by AppController.refreshUi.
  Future<void> _checkLocalSourceUpdates() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final result = await autoUpdateLocalSources(
      localSources: widget.services.localSources,
      controller: widget.services.controller,
    );
    if (!mounted || result.updated.isEmpty) return;
    _notifyRestart(result.updated);
  }

  /// Files were replaced under a running app. The pages and the player keep
  /// the build they loaded, so say plainly that a restart is what applies it,
  /// instead of silently running a half-updated state.
  final Set<String> _restartFor = <String>{};
  Timer? _restartNotice;

  void _notifyRestart(List<String> parts, {int attempt = 0}) {
    if (parts.isNotEmpty) _restartFor.addAll(parts);
    if (!mounted || _restartFor.isEmpty) return;
    _restartNotice?.cancel();
    // Batched: the source check and the core check finish seconds apart.
    _restartNotice = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final context = _navigatorKey.currentContext;
      if (context == null) {
        // The first frame may not be up yet; try again once soon after.
        if (attempt < 3) _notifyRestart(const [], attempt: attempt + 1);
        return;
      }
      final names = _restartFor.join('、');
      _restartFor.clear();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('$names已更新为新版本，请重新启动程序'),
          duration: const Duration(seconds: 15),
        ),
      );
    });
  }

  @override
  void dispose() {
    _restartNotice?.cancel();
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
