import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_navigator.dart';
import '../../app/app_scope.dart';
import '../../app/local_playlist_state.dart';
import '../../app/local_window_mode.dart';
import '../../core/gateway/core_download.dart';
import '../../core/gateway/source_api.dart';
import '../../core/library/local_library.dart';
import '../../core/local/local_dialogs.dart';
import '../../core/local/local_media.dart';
import '../../core/pages/account_sheet.dart';
import '../../core/pages/common.dart';
import '../../core/pages/detail_page.dart';
import '../../core/pages/navigation.dart';
import '../../core/pages/page_title.dart';
import '../../core/pages/player_page.dart';
import '../../core/pages/resume.dart';
import '../../core/pages/route.dart';
import '../../core/player/playback_coordinator.dart';
import '../../core/pages/search_page.dart';
import '../../core/pages/search_suggest_field.dart';
import '../../core/platform/platform.dart';
import '../../core/renderer/icons.dart';
import '../../core/renderer/manifest_menu.dart';
import '../../core/renderer/page_registry.dart';
import '../../core/sp/models.dart';
import '../../core/sp/page_types.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../l10n/strings.dart';
import '../settings/settings_page.dart';
import '../source/source_page.dart';
import '../source/source_switcher_button.dart';
import 'startup_digest.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  GlobalKey<NavigatorState> _contentNav = GlobalKey<NavigatorState>();
  _ContentNavObserver _contentObserver = _ContentNavObserver(() {});
  String _contentKey = '';
  Object? _lastShellState;
  bool _shellRebuildScheduled = false;
  AppController? _controller;
  // Test seam: `--dart-define=PAGE=list.rank` opens that page at startup.
  String _selectedPage = const String.fromEnvironment('PAGE');
  // Two local menu entries share library.history (历史 / 播放列表); the title
  // keeps the highlight on the one the user picked.
  String _selectedEntryTitle = '';
  // Test seam: open one series' detail page after startup.
  static const String _debugItem = String.fromEnvironment('ITEM');
  bool _debugItemOpened = false;
  // Guards against stacking two source pages from the mobile top bar.
  bool _sourcesOpen = false;
  bool _digestChecked = false;
  Map<String, String> _selectedParams = const {};
  // Switching sources lands on the new source's default page, not whichever
  // page the previous source happened to have open.
  String? _lastSourceId;
  AppNavigator? _appNavigator;
  LocalPlaylistState? _localPlaylist;
  LocalWindowMode? _windowMode;
  // Dark theme used only by the floating navigation over the home video. It
  // is cached because rebuilding ThemeData on every shell frame is wasteful.
  ThemeData? _overlayTheme;
  Color? _overlayThemeSeed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final playlist = AppScope.of(context).localPlaylist;
    if (!identical(playlist, _localPlaylist)) {
      _localPlaylist?.removeListener(_onLocalPlaylistChanged);
      _localPlaylist = playlist;
      playlist.addListener(_onLocalPlaylistChanged);
    }
    final windowMode = AppScope.of(context).windowMode;
    if (!identical(windowMode, _windowMode)) {
      _windowMode?.removeListener(_onWindowModeChanged);
      _windowMode = windowMode;
      windowMode.addListener(_onWindowModeChanged);
    }
    final navigator = AppScope.of(context).navigator;
    if (!identical(navigator, _appNavigator)) {
      _appNavigator?.removeListener(_onAppNavigatorRequest);
      _appNavigator = navigator;
      navigator.addListener(_onAppNavigatorRequest);
    }
    final controller = AppScope.controllerOf(context);
    if (!identical(_controller, controller)) {
      _controller?.removeListener(_onController);
      _controller = controller;
      _lastSourceId = controller.activeSourceId;
      _lastShellState = _shellStateOf(controller);
      controller.addListener(_onController);
      if (controller.pendingLocalPath != null ||
          controller.pendingSourceUrl != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onController();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onController);
    _appNavigator?.removeListener(_onAppNavigatorRequest);
    _localPlaylist?.removeListener(_onLocalPlaylistChanged);
    _windowMode?.removeListener(_onWindowModeChanged);
    super.dispose();
  }

  void _onLocalPlaylistChanged() {
    if (mounted) setState(() {});
  }

  void _onWindowModeChanged() {
    if (mounted) setState(() {});
  }

  /// Plays a local file in the content area, keeping the sidebar (and the
  /// file list in it) on screen. The player's maximize button can cover the
  /// sidebar without touching the OS window.
  void _playInContent(List<String> paths, String start, String title) {
    final navigator = _contentNav.currentState;
    if (navigator == null) return;
    // One player at a time: clicking another file swaps the episode rail
    // instead of stacking routes.
    navigator.popUntil((route) => route.isFirst);
    navigator
        .push(
          instantRoute(
            (_) => OpaquePage(
              child: PlayerScreen(
                plan: LocalMedia.buildPlan(start),
                title: title,
                itemId: paths.length == 1
                    ? 'local:$start'
                    : 'local:${File(start).parent.path}',
                localFiles: paths,
                episodeId: start,
                windowToggle: true,
              ),
            ),
          ),
        )
        .then((_) {
      // The history page caches its rows; rebuild it so the file just watched
      // is there when the player closes.
      if (mounted) setState(() => _contentKey = '');
    });
  }

  /// Clicking a file in the sidebar plays it with the rest of the session's
  /// files as the episode rail.
  Future<void> _openSidebarFile(String path) async {
    final playlist = _localPlaylist;
    if (playlist == null || playlist.files.isEmpty) return;
    Navigator.of(context, rootNavigator: true)
        .popUntil((route) => route.isFirst);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // Keep the list order stable: only the playhead moves to the chosen file.
    playlist.setPlaylist(playlist.files, title: playlist.title, current: path);
    _playInContent(playlist.files, path, playlist.title);
  }

  void _onAppNavigatorRequest() {
    final page = _appNavigator?.takeRequest();
    if (page == null || !mounted) return;
    setState(() {
      _selectedPage = page;
      _selectedParams = const {};
      _selectedEntryTitle = '';
    });
  }

  void _maybeOpenDebugItem(AppController controller) {
    if (_debugItem.isEmpty || _debugItemOpened) return;
    final api = controller.sourceApi;
    if (api == null) return;
    _debugItemOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final item = await api.detail(_debugItem);
        if (mounted) openDetail(context, api, item);
      } on Object {
        // Debug helper only.
      }
    });
  }

  /// Once per launch: follow-updates, premiered reservations, or the last
  /// played episode. Only logged-in accounts have remote lists.
  void _maybeShowDigest(AppController controller) {
    if (_digestChecked || controller.localMode || controller.isPreview) return;
    final api = controller.sourceApi;
    if (api == null) return;
    _digestChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The startup digest talks to several account lists. Let the first feed
      // card and its plan start before those calls; the prompt is passive and
      // can arrive a few seconds later without the app feeling slow.
      await Future<void>.delayed(const Duration(seconds: 12));
      if (!mounted) return;
      final library = AppScope.of(context).library;
      try {
        final user = await api.account();
        if (!mounted || !user.loggedIn) return;
        final digest = await loadStartupDigest(api, library);
        if (!mounted || digest.isEmpty) return;
        await showStartupDigest(
          context,
          digest,
          onOpenItem: (item) => _openItemDetail(controller, item),
          onContinue: (record) => _continueRecord(api, record),
          onOpenFollow: () => _selectPage(PageTypes.libraryFollow),
          onOpenHistory: () => _selectPage(PageTypes.libraryHistory),
        );
        await digest.markSeen();
      } on Object {
        // Startup prompts must never block the app.
      }
    });
  }

  void _selectPage(String page) {
    if (!mounted) return;
    setState(() {
      _selectedPage = page;
      _selectedParams = const {};
      _selectedEntryTitle = '';
    });
  }

  void _openItemDetail(AppController controller, Item item) {
    final api = controller.sourceApi;
    if (api == null) return;
    _contentNav.currentState?.push(
      instantRoute(
        (_) => OpaquePage(child: DetailContent(item: item, api: api)),
      ),
    );
  }

  Future<void> _continueRecord(SourceApi api, LibraryRecord record) async {
    try {
      final exit = await resumeLibraryRecord(context, api, record);
      if (exit != null && mounted) {
        // Keep the detail inside the shell: a root-level detail would cover
        // the sidebar and the back control.
        _contentNav.currentState?.push(
          instantRoute(
            (_) => OpaquePage(
              child: DetailContent(
                item: exit.item,
                api: api,
                poster: exit.poster,
              ),
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  /// Only the fields this shell renders. Volume, playback rate and other
  /// settings notifications used to rebuild the whole sidebar and content
  /// navigator while a video was playing.
  static Object _shellStateOf(AppController controller) => (
        controller.activeSourceId,
        controller.sourceRevision,
        controller.sourceApi,
        controller.isPreview,
        controller.uiManifest,
        controller.gatewayState,
        controller.localMode,
        controller.account,
        controller.loggedIn,
        controller.error,
        controller.coreDownload,
        controller.busy,
      );

  void _onController() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final state = _shellStateOf(controller);
    if (state != _lastShellState) {
      _lastShellState = state;
      setState(() {});
    }
    final sourceId = controller.activeSourceId;
    final previousSourceId = _lastSourceId;
    _lastSourceId = sourceId;
    if (previousSourceId != null && previousSourceId != sourceId) {
      setState(() {
        _selectedPage = '';
        _selectedParams = const {};
        _selectedEntryTitle = '';
      });
    }
    final link = controller.consumePendingSourceUrl();
    if (link != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installSourceLink(link);
      });
    }
    final path = controller.consumePendingLocalFile();
    if (path == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openLocal(path);
    });
  }

  /// Handles `freeplayer://source?url=…` from the website: a `.js` address is
  /// installed as a local script source, anything else is added as a gateway.
  Future<void> _installSourceLink(String link) async {
    final uri = Uri.tryParse(link);
    final target = (uri?.queryParameters['url'] ?? '').trim();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = _controller;
    if (target.isEmpty || controller == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('链接缺少源地址')));
      return;
    }
    final localSources = AppScope.of(context).localSources;
    try {
      if (Uri.tryParse(target)?.path.toLowerCase().endsWith('.js') ?? false) {
        final source = await localSources.installFromUrl(target, controller);
        messenger?.showSnackBar(
          SnackBar(content: Text('已安装源「${source.name}」')),
        );
      } else {
        await controller.addGateway(target);
        messenger?.showSnackBar(const SnackBar(content: Text('已添加源')));
      }
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('添加失败：$error')),
      );
    }
  }

  bool _openingLocal = false;

  Future<void> _openLocal(String path) async {
    // The launch intent and a duplicate delivery can both land here; the
    // second run would pop the player the first one just pushed.
    if (_openingLocal) return;
    _openingLocal = true;
    try {
      await _openLocalOnce(path);
    } finally {
      _openingLocal = false;
    }
  }

  Future<void> _openLocalOnce(String path) async {
    final isDir =
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
    final videos = LocalMedia.collectVideos([path]);
    if (videos.isEmpty) return;
    final controller = _controller;
    if (controller != null && !controller.localMode) {
      await controller.enableLocalMode();
      // Let the shell swap to its local content before the push below, or
      // the route lands in a navigator that is about to be rebuilt away.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    // A folder is a whole series and replaces the file list. A single file
    // joins whatever is already listed, so the sidebar keeps growing as files
    // are dropped in.
    final playlist = _localPlaylist;
    final existing = playlist?.files ?? const <String>[];
    final List<String> paths;
    final String title;
    if (isDir || existing.isEmpty) {
      paths = videos;
      title = _titleForPath(path);
    } else {
      paths = [
        ...existing.where((item) => !videos.contains(item)),
        ...videos,
      ];
      title = (playlist?.title.isNotEmpty ?? false)
          ? playlist!.title
          : _titleForPath(videos.first);
    }
    final start = videos.first;
    // A new drop replaces whatever player is on screen instead of stacking a
    // second route behind it.
    Navigator.of(context, rootNavigator: true)
        .popUntil((route) => route.isFirst);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    playlist?.setPlaylist(paths, title: title, current: start);
    // Switching into local mode mounts the content area on a later frame; an
    // intent that arrives while the shell still shows the picker has no
    // navigator to push onto yet. The first build can take a while, so keep
    // yielding frames instead of assuming a fixed frame count.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_contentNav.currentState == null &&
        mounted &&
        DateTime.now().isBefore(deadline)) {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    _playInContent(paths, start, title);
  }

  Future<void> _pickLocalFile() async {
    // Android copies the SAF selection into app storage before the player
    // can open it; a large episode can take a while with the picker closed.
    final messenger = isAndroidPlatform ? ScaffoldMessenger.maybeOf(context) : null;
    if (messenger != null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('正在导入视频，大文件需要一点时间…'),
        duration: Duration(minutes: 5),
      ));
    }
    final path = await LocalDialogs.pickFile();
    messenger?.hideCurrentSnackBar();
    if (path != null && mounted) await _openLocal(path);
  }

  Future<void> _pickLocalFolder() async {
    final path = await LocalDialogs.pickFolder();
    if (path != null && mounted) await _openLocal(path);
  }

  /// Clears the sidebar's file list and the local playback history. Files on
  /// disk are untouched.
  Future<void> _clearLocalHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空文件历史'),
        content: const Text('只会清空左侧文件列表和播放记录，不会删除任何本地文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Stop whatever file is playing: its next progress tick would otherwise
    // write the history row straight back.
    _contentNav.currentState?.popUntil((route) => route.isFirst);
    _localPlaylist?.clear();
    final library = AppScope.of(context).library;
    final history = await library.history();
    final keys = history
        .where((record) => record.sourceId == 'local')
        .map((record) => record.seriesKey)
        .toSet();
    if (keys.isNotEmpty) await library.removeHistory(keys);
    if (!mounted) return;
    // The page caches its records; force a fresh build so the cleared history
    // is what the user sees.
    setState(() => _contentKey = '');
  }

  String _titleForPath(String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
      final segments =
          Directory(path).uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) return segments.last;
    }
    return LocalMedia.titleFor(path);
  }

  @override
  Widget build(BuildContext context) {
    return _buildShell(context, AppScope.controllerOf(context));
  }

  Widget _buildShell(BuildContext context, AppController controller) {
    final scope = AppScope.of(context);
    final capabilities = controller.sourceApi?.manifest.capabilities ??
        controller.activeSource?.capabilities ??
        const <String>[];
    final localMode = controller.localMode || controller.sourceApi == null;
    final menu = buildMenu(
      manifest: controller.uiManifest,
      capabilities: capabilities,
      localMode: localMode,
      supportedPages: scope.pageRegistry.registeredTypes.toSet(),
    );
    final defaultPage =
        defaultPageOf(manifest: controller.uiManifest, menu: menu);
    _maybeOpenDebugItem(controller);
    _maybeShowDigest(controller);
    final hasSelected = _pageExists(menu, _selectedPage);
    final page = hasSelected ? _selectedPage : defaultPage;
    // Whole-window local playback: the player asked for the sidebar to go
    // away without leaving the app window.
    final maximized = localMode && (_windowMode?.maximized ?? false);
    final params = hasSelected ? _selectedParams : const <String, String>{};
    final selectedTitle = _selectedEntryTitle.isNotEmpty
        ? _selectedEntryTitle
        : _firstEntryTitle(menu, page);

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < AppSizes.drawerWidth;
        // The account belongs to one source: local mode and sources without
        // an auth capability show neither the login entry nor the profile.
        final showAccount = !localMode && capabilities.contains('auth');
        final contentCanPop = _contentNav.currentState?.canPop() ?? false;
        // Home is the one page whose background is the video itself: the
        // sidebar floats over it instead of reserving a column. As soon as a
        // route is pushed there (detail/search), the backdrop is an opaque
        // page again — keeping the scrim would paint a dark wash over a light
        // page and leave the nav's labels unreadable.
        final immersive = page == PageTypes.homeFeed &&
            !narrow &&
            !maximized &&
            !contentCanPop;
        // The window chrome becomes transparent only on the home root; the
        // app uses this to drop the reserved title-bar strip.
        final overMediaTitleBar =
            (page == PageTypes.homeFeed && !contentCanPop) || maximized;
        final titleController = PageTitleScope.maybeOf(context);
        if (titleController != null &&
            titleController.overMedia.value != overMediaTitleBar) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) titleController.overMedia.value = overMediaTitleBar;
          });
        }
        // The rail background runs to the very top; only its content clears
        // the floating drag bar so there is no visual seam. Android has no
        // window chrome: the status bar is the only inset above the page.
        final titleBarInset = controller.immersive
            ? 0.0
            : isMobilePlatform
                ? MediaQuery.paddingOf(context).top
                : AppSizes.titleBar;
        final sidebar = _Sidebar(
          overlay: immersive,
          contentTopInset: titleBarInset,
          menu: menu,
          selectedPage: page,
          selectedTitle: selectedTitle,
          localMode: localMode,
          localFiles: localMode ? (_localPlaylist?.files ?? const []) : const [],
          localCurrent: localMode ? (_localPlaylist?.current ?? '') : '',
          onOpenLocalFile: _openSidebarFile,
          onOpenFile: _pickLocalFile,
          onOpenFolder: _pickLocalFolder,
          onClearLocal: _clearLocalHistory,
          account: showAccount ? controller.account : null,
          loggedIn: showAccount && controller.loggedIn,
          canLogin: showAccount,
          onLogin: () => showAccountDialog(context, controller),
          onAccount: () => showAccountDialog(context, controller),
          onSelect: (entry) {
            _scaffoldKey.currentState?.closeDrawer();
            setState(() {
              _selectedPage = entry.page;
              _selectedParams = entry.params;
              _selectedEntryTitle = entry.title;
            });
          },
          onSettings: _openSettings,
          onAction: _pendingAction,
        );

        // Home is video-only on desktop: no title, no search box. A pushed
        // route (e.g. detail) brings the bar back so its back button stays
        // reachable. Android needs the bar everywhere — without it the feed
        // has no drawer, search or source switch.
        final showTopBar =
            isMobilePlatform || page != PageTypes.homeFeed || contentCanPop;
        ThemeData? overlayTheme;
        if (immersive) {
          if (_overlayTheme == null || _overlayThemeSeed != controller.themeSeed) {
            _overlayThemeSeed = controller.themeSeed;
            _overlayTheme = buildAppTheme(
              brightness: Brightness.dark,
              seed: controller.themeSeed,
            );
          }
          overlayTheme = _overlayTheme;
        }
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                _openSearch,
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openSearch,
          },
          child: Scaffold(
            key: _scaffoldKey,
            drawer: narrow && !maximized
                ? Drawer(
                    width: 236,
                    child: isMobilePlatform
                        // The rail already pads for the status bar itself;
                        // leave the bottom and gesture insets to SafeArea.
                        ? SafeArea(top: false, child: sidebar)
                        : sidebar,
                  )
                : null,
            body: Stack(
              children: [
                Row(
                  children: [
                    if (!narrow && !maximized && !immersive) sidebar,
                    Expanded(
                      child: Column(
                        children: [
                          if (!maximized && showTopBar)
                            _topBar(
                              context,
                              narrow: narrow,
                              menu: menu,
                              fallbackTitle: _titleFor(menu, page),
                              leftInset:
                                  immersive ? AppSizes.sidebar : 0,
                              topInset: titleBarInset,
                            ),
                          if (!maximized && controller.error != null)
                            _StatusBanner(
                              message: controller.error!,
                              onRetry: controller.refreshUi,
                            ),
                          if (!maximized &&
                              controller.coreDownload != null)
                            _CoreDownloadBanner(
                              state: controller.coreDownload!,
                            ),
                          Expanded(
                            child: immersive && contentCanPop
                                ? Padding(
                                    padding: const EdgeInsets.only(
                                      left: AppSizes.sidebar,
                                    ),
                                    child: _content(
                                      controller,
                                      page,
                                      params,
                                    ),
                                  )
                                : _content(controller, page, params),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (immersive && overlayTheme != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Theme(data: overlayTheme, child: sidebar),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _content(
    AppController controller,
    String page,
    Map<String, String> params,
  ) {
    final contentKey =
        '${controller.activeSourceId}|$page|${params.hashCode}|${controller.sourceRevision}';
    if (_contentKey != contentKey) {
      _contentKey = contentKey;
      // Leaving a page must stop its video. The player itself lives on the
      // root navigator, so this only fires for content pages (the feed).
      unawaited(PlaybackCoordinator.instance.pauseAll());
      // A fresh navigator per page keeps pushed routes from leaking into the
      // next page; the observer lets the top bar follow push/pop.
      _contentNav = GlobalKey<NavigatorState>();
      _contentObserver = _ContentNavObserver(_scheduleShellRebuild);
    }
    // A short cross-fade between sidebar pages: the content navigator is
    // rebuilt per page, so the switcher is what makes switching read as a
    // transition instead of a hard cut.
    return AnimatedSwitcher(
      duration: AppDuration.page,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(
        key: ValueKey(contentKey),
        // The content pages live in their own navigator. Android's system
        // back must pop that stack before it reaches the app route.
        child: NavigatorPopHandler(
          onPopWithResult: (_) => _contentNav.currentState?.maybePop(),
          child: Navigator(
            key: _contentNav,
            observers: [_contentObserver],
            onGenerateRoute: (settings) => instantRoute(
              (routeContext) => OpaquePage(
                child: _pageWidget(routeContext, controller, page, params),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scheduleShellRebuild() {
    if (_shellRebuildScheduled || !mounted) return;
    _shellRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shellRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  Widget _pageWidget(
    BuildContext context,
    AppController controller,
    String page,
    Map<String, String> params,
  ) {
    final scope = AppScope.of(context);
    final ctx = PageContext(
      sourceId: controller.activeSourceId,
      params: params,
    );
    return scope.pageRegistry.build(page, context, ctx) ??
        const StatePanel(
          icon: Icons.extension_outlined,
          title: AppStrings.unsupportedTitle,
          body: AppStrings.unsupportedBody,
        );
  }

  Widget _topBar(
    BuildContext context, {
    required bool narrow,
    required List<MenuGroup> menu,
    required String fallbackTitle,
    double leftInset = 0,
    double topInset = 0,
  }) {
    final tokens = AppTokens.of(context);
    final canSearch = menu.any((group) =>
        group.entries.any((entry) => entry.page == PageTypes.search));
    final navigator = _contentNav.currentState;
    final canPop = navigator?.canPop() ?? false;
    final Widget? leading;
    if (canPop) {
      leading = IconButton(
        tooltip: AppStrings.backToPrevious,
        onPressed: () => navigator?.maybePop(),
        icon: const Icon(Icons.arrow_back),
      );
    } else if (narrow) {
      leading = IconButton(
        tooltip: AppStrings.expandSidebar,
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        icon: const Icon(Icons.menu),
      );
    } else {
      leading = null;
    }
    final titleController = PageTitleScope.maybeOf(context);
    final titleStyle = TextStyle(
      fontSize: AppFontSize.bodyLg,
      fontWeight: FontWeight.w600,
      color: tokens.colors.text,
    );
    Widget title = Text(
      fallbackTitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
    if (titleController != null) {
      title = ValueListenableBuilder<bool>(
        valueListenable: titleController.hideTitle,
        builder: (context, hidden, _) {
          if (hidden) return const SizedBox.shrink();
          return ValueListenableBuilder<String>(
            valueListenable: titleController.listenable,
            builder: (context, value, _) => Text(
              value.isEmpty ? fallbackTitle : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          );
        },
      );
    }
    return Container(
      // The strip behind the floating window chrome belongs to this bar, so
      // the title bar never needs a separate reserved row.
      height: AppSizes.topBar + topInset,
      padding: EdgeInsets.only(
        left: leftInset + AppSpacing.x2,
        right: AppSpacing.x2,
        top: topInset,
      ),
      decoration: BoxDecoration(
        color: tokens.colors.surface,
        border: Border(bottom: BorderSide(color: tokens.colors.border)),
      ),
      child: Row(
        children: [
          if (leading != null) leading,
          const SizedBox(width: AppSpacing.x1),
          Expanded(child: title),
          if (canSearch)
            if (isMobilePlatform)
              IconButton(
                tooltip: AppStrings.search,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _contentNav.currentState?.push(
                    instantRoute(
                      (_) => const OpaquePage(child: SearchPage()),
                    ),
                  );
                },
                icon: const Icon(Icons.search, size: 20),
              )
            else
              SearchSuggestField(
                api: AppScope.controllerOf(context).sourceApi,
                onSubmit: (query) {
                  _contentNav.currentState?.push(
                    instantRoute(
                      (_) => OpaquePage(
                        child: SearchPage(initialQuery: query),
                      ),
                    ),
                  );
                },
              ),
          if (isMobilePlatform)
            SourceSwitcherButton(
              colors: tokens.colors,
              onOpen: _openSourceManager,
            ),
        ],
      ),
    );
  }

  Future<void> _openSourceManager() async {
    if (_sourcesOpen || !mounted) return;
    _sourcesOpen = true;
    unawaited(PlaybackCoordinator.instance.pauseAll());
    try {
      await Navigator.of(context, rootNavigator: true)
          .push(instantRoute((_) => const SourcePage()));
    } finally {
      _sourcesOpen = false;
    }
  }

  String _titleFor(List<MenuGroup> menu, String page) {
    for (final group in menu) {
      for (final entry in group.entries) {
        if (entry.page == page) return entry.title;
      }
    }
    return AppStrings.appName;
  }

  void _openSearch() {
    final api = _controller?.sourceApi;
    final navigator = _contentNav.currentState;
    if (api == null || navigator == null) return;
    navigator.push(
      instantRoute((_) => const OpaquePage(child: SearchPage())),
    );
  }

  void _openSettings() {
    unawaited(PlaybackCoordinator.instance.pauseAll());
    // Inside the content navigator so the sidebar stays visible, like every
    // other page.
    _contentNav.currentState?.push(
      instantRoute((_) => const OpaquePage(child: SettingsPage())),
    );
  }

  void _pendingAction(MenuEntry entry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${entry.title}: ${AppStrings.featurePending}')),
    );
  }

  String _firstEntryTitle(List<MenuGroup> menu, String page) {
    for (final group in menu) {
      for (final entry in group.entries) {
        if (entry.page == page) return entry.title;
      }
    }
    return '';
  }

  bool _pageExists(List<MenuGroup> menu, String page) {
    if (page.isEmpty) return false;
    for (final group in menu) {
      for (final entry in group.entries) {
        if (entry.page == page) return true;
      }
    }
    return false;
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.menu,
    required this.selectedPage,
    required this.selectedTitle,
    required this.localMode,
    required this.localFiles,
    required this.localCurrent,
    required this.onOpenLocalFile,
    required this.onOpenFile,
    required this.onOpenFolder,
    required this.onClearLocal,
    required this.account,
    required this.loggedIn,
    required this.canLogin,
    required this.onLogin,
    required this.onAccount,
    required this.onSelect,
    required this.onSettings,
    required this.onAction,
    this.overlay = false,
    this.contentTopInset = 0,
  });

  /// True when the rail floats over the home video instead of owning a
  /// column: the surface becomes a translucent scrim.
  final bool overlay;

  /// Clears the transparent window drag bar; the rail background itself
  /// still starts at the very top.
  final double contentTopInset;

  final List<MenuGroup> menu;
  final String selectedPage;
  final String selectedTitle;
  final bool localMode;
  final List<String> localFiles;
  final String localCurrent;
  final ValueChanged<String> onOpenLocalFile;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenFolder;
  final VoidCallback onClearLocal;
  final AccountUser? account;
  final bool loggedIn;
  final bool canLogin;
  final VoidCallback onLogin;
  final VoidCallback onAccount;
  final void Function(MenuEntry entry) onSelect;
  final VoidCallback onSettings;
  final void Function(MenuEntry entry) onAction;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  String? _hoveredKey;

  void _setHovered(String key, bool hovered) {
    setState(() {
      if (hovered) {
        _hoveredKey = key;
      } else if (_hoveredKey == key) {
        _hoveredKey = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.menu;
    final selectedPage = widget.selectedPage;
    final onSelect = widget.onSelect;
    final onSettings = widget.onSettings;
    final onAction = widget.onAction;
    final tokens = AppTokens.of(context);
    return Container(
      width: AppSizes.sidebar,
      decoration: widget.overlay
          ? BoxDecoration(
              // A flat scrim, not a backdrop blur: the home video repaints
              // every frame and a blur would be recomputed on each one.
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.58),
                  Colors.black.withValues(alpha: 0.40),
                  Colors.black.withValues(alpha: 0.16),
                  Colors.transparent,
                ],
                stops: const [0, 0.62, 0.88, 1],
              ),
              // No light hairline on the boundary: against video it read as
              // a white edge on the rail.
            )
          : BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tokens.colors.surface,
                  tokens.colors.bg,
                ],
                stops: const [0, 0.55],
              ),
            ),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                0,
                widget.contentTopInset + AppSpacing.x2,
                0,
                AppSpacing.x2,
              ),
              children: [
                // Hover is keyed by the tile's position, not by page|title:
                // the manifest can repeat an entry (same page and title) in
                // two groups, and a shared key lit up both rows at once.
                for (var gi = 0; gi < menu.length; gi++) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.x4,
                      AppSpacing.x3,
                      AppSpacing.x4,
                      AppSpacing.x1,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            color: tokens.colors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x1),
                        Text(
                          menu[gi].title,
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (var ei = 0; ei < menu[gi].entries.length; ei++)
                    _NavTile(
                      entry: menu[gi].entries[ei],
                      // Require the page too: matching the title alone lit up
                      // a same-named entry on another page, so two rows looked
                      // selected at once.
                      selected: menu[gi].entries[ei].page == selectedPage &&
                          (widget.selectedTitle.isEmpty ||
                              menu[gi].entries[ei].title ==
                                  widget.selectedTitle),
                      hovered: _hoveredKey == '$gi/$ei',
                      onHover: (value) => _setHovered('$gi/$ei', value),
                      onTap: () => onSelect(menu[gi].entries[ei]),
                      onAction: menu[gi].entries[ei].actions.isEmpty
                          ? null
                          : () => onAction(menu[gi].entries[ei]),
                    ),
                ],
                if (widget.localMode) ...[
                  const SizedBox(height: AppSpacing.x2),
                  _SidebarActionTile(
                    icon: Icons.video_file_outlined,
                    label: '打开文件',
                    onTap: widget.onOpenFile,
                  ),
                  if (!isMobilePlatform)
                    _SidebarActionTile(
                      icon: Icons.folder_open_outlined,
                      label: '打开文件夹',
                      onTap: widget.onOpenFolder,
                    ),
                  _SidebarActionTile(
                    icon: Icons.delete_sweep_outlined,
                    label: '清空文件历史',
                    muted: true,
                    onTap: widget.onClearLocal,
                  ),
                ],
                if (widget.localFiles.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.x4,
                      AppSpacing.x3,
                      AppSpacing.x4,
                      AppSpacing.x1,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            color: tokens.colors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x1),
                        Text(
                          '文件',
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final path in widget.localFiles.take(200))
                    _LocalFileTile(
                      path: path,
                      selected: path == widget.localCurrent,
                      onTap: () => widget.onOpenLocalFile(path),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x2),
            child: Column(
              children: [
                if (!widget.loggedIn && widget.canLogin) ...[
                  _FooterTile(
                    icon: Icons.login,
                    label: AppStrings.login,
                    color: tokens.colors.accent,
                    onTap: widget.onLogin,
                  ),
                  const SizedBox(height: AppSpacing.x1),
                ],
                if (widget.loggedIn)
                  _UserFooter(
                    account: widget.account,
                    onTap: widget.onAccount,
                    onSettings: onSettings,
                  )
                else
                  _FooterTile(
                    icon: Icons.settings_outlined,
                    label: AppStrings.settings,
                    color: tokens.colors.text2,
                    onTap: onSettings,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterTile extends StatelessWidget {
  const _FooterTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              label,
              style: TextStyle(fontSize: AppFontSize.body, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// Logged-in rail footer: the settings entry becomes the account card. It
/// draws no card surface, so over the home video it reads as part of the rail.
class _UserFooter extends StatefulWidget {
  const _UserFooter({
    required this.account,
    required this.onTap,
    required this.onSettings,
  });

  final AccountUser? account;
  final VoidCallback onTap;
  final VoidCallback onSettings;

  @override
  State<_UserFooter> createState() => _UserFooterState();
}

class _UserFooterState extends State<_UserFooter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final user = widget.account;
    final avatar = user?.avatar ?? '';
    final name =
        (user == null || user.userName.isEmpty) ? '已登录' : user.userName;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDuration.micro,
          curve: AppDuration.ease,
          decoration: BoxDecoration(
            color: _hover
                ? tokens.colors.surface2.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x2,
              AppSpacing.x2,
              AppSpacing.x1,
              AppSpacing.x2,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: tokens.colors.surface3,
                        backgroundImage:
                            avatar.isEmpty ? null : NetworkImage(avatar),
                        child: avatar.isEmpty
                            ? Icon(
                                Icons.person,
                                size: 16,
                                color: tokens.colors.text3,
                              )
                            : null,
                      ),
                      Positioned(
                        right: 1,
                        bottom: 1,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: tokens.colors.success,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: tokens.colors.bg,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.xs,
                          fontWeight: FontWeight.w600,
                          color: tokens.colors.text,
                        ),
                      ),
                      Text(
                        '点击查看账号',
                        style: TextStyle(
                          fontSize: AppFontSize.xxs,
                          color: tokens.colors.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  // No tooltip in the rail: the label popup over the video was
                  // more noise than help.
                  onPressed: widget.onSettings,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: 18,
                    color: tokens.colors.text2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarActionTile extends StatelessWidget {
  const _SidebarActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final color = muted ? tokens.colors.text3 : tokens.colors.text2;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x2,
          vertical: 1,
        ),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
        child: Row(
          children: [
            SizedBox(width: AppSpacing.x1 + 3),
            const SizedBox(width: AppSpacing.x3),
            Icon(icon, size: 18, color: color),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.body,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalFileTile extends StatefulWidget {
  const _LocalFileTile({
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LocalFileTile> createState() => _LocalFileTileState();
}

class _LocalFileTileState extends State<_LocalFileTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final name = LocalMedia.titleFor(widget.path);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDuration.micro,
          curve: AppDuration.ease,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
          color: widget.selected
              ? tokens.colors.accentWeak
              : _hovered
                  ? tokens.colors.surface2.withValues(alpha: 0.7)
                  : Colors.transparent,
          child: Row(
            children: [
              Icon(
                widget.selected
                    ? Icons.play_arrow_rounded
                    : Icons.play_circle_outline,
                size: 15,
                color: widget.selected
                    ? tokens.colors.accent
                    : _hovered
                        ? tokens.colors.text2
                        : tokens.colors.text3,
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: widget.selected
                        ? tokens.colors.accent
                        : tokens.colors.text2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.entry,
    required this.selected,
    required this.hovered,
    required this.onHover,
    required this.onTap,
    this.onAction,
  });

  final MenuEntry entry;
  final bool selected;
  final bool hovered;
  final void Function(bool hovered) onHover;
  final VoidCallback onTap;
  final VoidCallback? onAction;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final entry = widget.entry;
    final selected = widget.selected;
    final hovered = widget.hovered;
    final color = selected
        ? tokens.colors.accent
        : hovered
            ? tokens.colors.text
            : tokens.colors.text2;
    final tile = FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => widget.onHover(true),
        onExit: (_) => widget.onHover(false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppDuration.micro,
            curve: AppDuration.ease,
            margin: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x2,
              vertical: 1,
            ),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
            decoration: BoxDecoration(
              // Only the selected row has a fill. A hovered row lit up with its
              // own wash looked like a second selection next to the accent
              // tint; hover now reads from the text and the small left bar.
              color: selected ? tokens.colors.accentWeak : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: _focused ? tokens.colors.accent : Colors.transparent,
                width: AppSizes.focusRing,
              ),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppDuration.micro,
                  width: 3,
                  height: 18,
                  margin: const EdgeInsets.only(left: AppSpacing.x1),
                  decoration: BoxDecoration(
                    color: selected
                        ? tokens.colors.accent
                        : hovered
                            ? tokens.colors.text3.withValues(alpha: 0.4)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Icon(iconFor(entry.icon), size: 18, color: color),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: color,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.onAction != null)
                  InkWell(
                    onTap: widget.onAction,
                    child: Icon(
                      iconFor(entry.actions.first.icon),
                      size: 16,
                      color: tokens.colors.text3,
                    ),
                  ),
                const SizedBox(width: AppSpacing.x2),
              ],
            ),
          ),
        ),
      ),
    );
    return tile;
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      width: double.infinity,
      color: tokens.colors.surface2,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x4,
        vertical: AppSpacing.x1,
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off, size: 14, color: tokens.colors.text3),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.xxs,
                color: tokens.colors.text2,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text(AppStrings.retry),
          ),
        ],
      ),
    );
  }
}

/// Download progress for the source core: one line with MB and percent.
class _CoreDownloadBanner extends StatelessWidget {
  const _CoreDownloadBanner({required this.state});

  final CoreDownloadState state;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      width: double.infinity,
      color: tokens.colors.surface2,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x4,
        vertical: AppSpacing.x2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.downloading, size: 14, color: tokens.colors.accent),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  state.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppFontSize.xxs,
                    color: tokens.colors.text2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x1),
          LinearProgressIndicator(
            value: state.fraction,
            minHeight: 2,
            backgroundColor: tokens.colors.surface,
            valueColor: AlwaysStoppedAnimation<Color>(tokens.colors.accent),
          ),
        ],
      ),
    );
  }
}

class _ContentNavObserver extends NavigatorObserver {
  _ContentNavObserver(this.onChanged);

  final VoidCallback onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A page pushed inside the shell (detail, search, library…) is not a video
    // page: never let the feed keep decoding under it.
    unawaited(PlaybackCoordinator.instance.pauseAll());
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    onChanged();
  }
}

/// Full-window hint while a file or folder is dragged over the app.
