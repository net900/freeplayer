import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
  bool _digestChecked = false;
  Map<String, String> _selectedParams = const {};
  // Switching sources lands on the new source's default page, not whichever
  // page the previous source happened to have open.
  String? _lastSourceId;
  AppNavigator? _appNavigator;
  LocalPlaylistState? _localPlaylist;
  LocalWindowMode? _windowMode;

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
      controller.addListener(_onController);
      if (controller.pendingLocalPath != null) {
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

  void _onController() {
    final controller = _controller;
    if (controller == null || !mounted) return;
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

  Future<void> _openLocal(String path) async {
    final isDir =
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
    final videos = LocalMedia.collectVideos([path]);
    if (videos.isEmpty) return;
    final controller = _controller;
    if (controller != null && !controller.localMode) {
      await controller.enableLocalMode();
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
    _playInContent(paths, start, title);
  }

  Future<void> _pickLocalFile() async {
    final path = await LocalDialogs.pickFile();
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
    final controller = AppScope.controllerOf(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildShell(context, controller),
    );
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
        final sidebar = _Sidebar(
          header: _sourceSwitcher(context, controller),
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

        // Home is video-only: no title, no search box. A pushed route (e.g.
        // detail) brings the bar back so its back button stays reachable.
        final showTopBar = page != PageTypes.homeFeed ||
            (_contentNav.currentState?.canPop() ?? false);
        return Scaffold(
          key: _scaffoldKey,
          drawer: narrow && !maximized
              ? Drawer(width: 236, child: sidebar)
              : null,
          body: Row(
            children: [
              if (!narrow && !maximized) sidebar,
              Expanded(
                child: Column(
                  children: [
                    if (!maximized && showTopBar)
                      _topBar(
                        context,
                        narrow: narrow,
                        menu: menu,
                        fallbackTitle: _titleFor(menu, page),
                      ),
                    if (!maximized && controller.error != null)
                      _StatusBanner(
                        message: controller.error!,
                        onRetry: controller.refreshUi,
                      ),
                    if (!maximized && controller.coreDownload != null)
                      _CoreDownloadBanner(state: controller.coreDownload!),
                    Expanded(child: _content(controller, page, params)),
                  ],
                ),
              ),
            ],
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
    return Navigator(
      key: _contentNav,
      observers: [_contentObserver],
      onGenerateRoute: (settings) => instantRoute(
        (routeContext) => OpaquePage(
          child: _pageWidget(routeContext, controller, page, params),
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
      height: AppSizes.topBar,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
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
        ],
      ),
    );
  }

  String _titleFor(List<MenuGroup> menu, String page) {
    for (final group in menu) {
      for (final entry in group.entries) {
        if (entry.page == page) return entry.title;
      }
    }
    return AppStrings.appName;
  }

  Widget _sourceSwitcher(
    BuildContext context,
    AppController controller,
  ) {
    final tokens = AppTokens.of(context);
    final label = Container(
      width: double.infinity,
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
      decoration: BoxDecoration(
        color: tokens.colors.surface2.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: tokens.colors.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              Icons.play_circle_fill,
              color: tokens.colors.accent,
              size: 17,
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              controller.activeSourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!controller.isPreview) ...[
            const SizedBox(width: AppSpacing.x1),
            Icon(Icons.expand_more, size: 16, color: tokens.colors.text3),
          ],
        ],
      ),
    );
    if (controller.isPreview) {
      // Preview has nothing to switch between: tapping goes back to the
      // mode picker instead of opening the source page.
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.exitPreview(),
          child: label,
        ),
      );
    }
    return Tooltip(
      message: AppStrings.switchSource,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openSources(controller),
          child: label,
        ),
      ),
    );
  }

  /// A full page instead of a dropdown: switch, add, edit or remove a source.
  /// Switching returns to the app's start page.
  Future<void> _openSources(AppController controller) async {
    unawaited(PlaybackCoordinator.instance.pauseAll());
    final changed = await Navigator.of(context).push<bool>(
      instantRoute((_) => const SourcePage()),
    );
    if (!mounted || changed != true) return;
    setState(() {
      _selectedPage = '';
      _selectedParams = const {};
      _selectedEntryTitle = '';
    });
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
    required this.header,
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
  });

  final Widget header;
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

  String _keyFor(MenuEntry entry) => '${entry.page}|${entry.title}';

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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            tokens.colors.surface,
            tokens.colors.bg,
          ],
          stops: const [0, 0.55],
        ),
        border: Border(
          right: BorderSide(
            color: tokens.colors.border.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: AppSizes.topBar,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: tokens.colors.border),
              ),
            ),
            child: Center(child: widget.header),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
              children: [
                for (final group in menu) ...[
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
                          group.title,
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: tokens.colors.border.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final entry in group.entries)
                    _NavTile(
                      entry: entry,
                      selected: widget.selectedTitle.isNotEmpty
                          ? entry.title == widget.selectedTitle
                          : entry.page == selectedPage,
                      hovered: _hoveredKey == _keyFor(entry),
                      onHover: (value) => _setHovered(_keyFor(entry), value),
                      onTap: () => onSelect(entry),
                      onAction:
                          entry.actions.isEmpty ? null : () => onAction(entry),
                    ),
                ],
                if (widget.localMode) ...[
                  const SizedBox(height: AppSpacing.x2),
                  _SidebarActionTile(
                    icon: Icons.video_file_outlined,
                    label: '打开文件',
                    onTap: widget.onOpenFile,
                  ),
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
                        const SizedBox(width: AppSpacing.x2),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: tokens.colors.border.withValues(alpha: 0.6),
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
          Container(height: 1, color: tokens.colors.border),
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
    return Tooltip(
      message: label,
      child: InkWell(
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
      ),
    );
  }
}

/// Logged-in rail footer: the settings entry becomes the account card.
class _UserFooter extends StatelessWidget {
  const _UserFooter({
    required this.account,
    required this.onTap,
    required this.onSettings,
  });

  final AccountUser? account;
  final VoidCallback onTap;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final user = account;
    final avatar = user?.avatar ?? '';
    final name = (user == null || user.userName.isEmpty) ? '已登录' : user.userName;
    return Container(
      decoration: BoxDecoration(
        color: tokens.colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.colors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
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
                            color: tokens.colors.surface2,
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
                      style: const TextStyle(
                        fontSize: AppFontSize.xs,
                        fontWeight: FontWeight.w600,
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
                tooltip: AppStrings.settings,
                onPressed: onSettings,
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
    return Tooltip(
      message: label,
      child: InkWell(
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
      ),
    );
  }
}

class _LocalFileTile extends StatelessWidget {
  const _LocalFileTile({
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final name = LocalMedia.titleFor(path);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
        color: selected
            ? tokens.colors.accentWeak
            : Colors.transparent,
        child: Row(
          children: [
            Icon(
              selected ? Icons.play_arrow_rounded : Icons.play_circle_outline,
              size: 15,
              color: selected ? tokens.colors.accent : tokens.colors.text3,
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? tokens.colors.accent : tokens.colors.text2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final color = selected
        ? tokens.colors.accent
        : hovered
            ? tokens.colors.text
            : tokens.colors.text2;
    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x2,
            vertical: 1,
          ),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
          decoration: BoxDecoration(
            color: selected
                ? tokens.colors.accentWeak
                : hovered
                    ? tokens.colors.surface2.withValues(alpha: 0.75)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AppDuration.micro,
                width: 3,
                height: 18,
                margin: const EdgeInsets.only(left: AppSpacing.x1),
                decoration: BoxDecoration(
                  color: selected ? tokens.colors.accent : Colors.transparent,
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
              if (onAction != null)
                InkWell(
                  onTap: onAction,
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
    );
    return Tooltip(message: entry.title, child: tile);
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
