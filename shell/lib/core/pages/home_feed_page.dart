import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../player/playback_engine.dart';
import '../player/playback_pool.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import '../sp/quality.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import '../widgets/cover_image.dart';
import 'home_feed_widgets.dart';
import 'loading.dart';
import 'navigation.dart';
import 'login_sheet.dart';
import 'page_title.dart';
import 'player_page.dart';

/// Home is a full-screen vertical feed. The glass bar on top switches the
/// source-provided tab; one wheel notch moves one video.
class HomeFeedPage extends StatefulWidget {
  const HomeFeedPage({super.key, required this.ctx});

  final PageContext ctx;

  @override
  State<HomeFeedPage> createState() => _HomeFeedPageState();
}

class _HomeFeedPageState extends State<HomeFeedPage> {
  static const _pageSize = 20;

  // The active card plus N neighbours, opened paused. N comes from
  // 设置 → 预加载数量.
  late final PlaybackPool _pool;
  late final int _preloadAhead;

  PlaybackEngine get _engine => _pool.active;

  final PageController _pageController = PageController();
  final FocusNode _focusNode = FocusNode();

  // Tabs are source data, never shell defaults: the UI manifest carries them.
  List<HomeTab> _tabs = const [];
  HomeTab? _tab;

  List<Item> _items = const [];
  final Map<String, ItemStats> _stats = {};
  final Map<String, MediaPlan> _plans = {};
  final Set<String> _warming = {};

  int _index = 0;
  String _playingEpisodeId = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _opening = false;
  bool _started = false;
  String? _error;
  String _next = '';
  // Playback position per feed card: swiping away and back must resume where
  // the viewer left, not restart the drama.
  String? _playingId;
  final Map<String, Duration> _resume = {};
  bool _needsLogin = false;
  final Map<String, int> _prefetchedAt = {};
  SourceApi? _api;
  Timer? _openTimer;
  int _openToken = 0;
  int _epoch = 0;
  int _lastWheelMs = 0;
  int _preloadGeneration = 0;
  int _retryIndex = -1;
  Timer? _openWatchdog;
  // Some tabs only carry a card-sized upstream cell; after it runs out the
  // feed continues from the category the source attached to that tab, so
  // swiping never hits a wall.
  bool _categoryFallback = false;
  String _categoryTag = '';
  AppController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.controllerOf(context);
    if (!identical(controller, _controller)) {
      _controller?.removeListener(_onController);
      _controller = controller;
      controller.addListener(_onController);
    }
    if (_started) return;
    _started = true;
    _preloadAhead = controller.settings.preloadAhead.clamp(1, 4);
    _pool = PlaybackPool(size: _preloadAhead + 1, fit: BoxFit.contain);
    _api = controller.sourceApi;
    final configured = controller.uiManifest?.homeTabs ?? const <HomeTab>[];
    if (configured.isNotEmpty) {
      _tabs = configured;
      _tab = configured.first;
      _load();
    } else {
      unawaited(_bootstrapTabs());
    }
  }

  /// The source can arrive after the first paint: the bundled core starts in
  /// the background, so the page is built while [sourceApi] is still null.
  /// Once it appears, load the feed instead of leaving the empty state.
  void _onController() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final api = controller.sourceApi;
    if (api == null || identical(api, _api)) return;
    _api = api;
    final configured = controller.uiManifest?.homeTabs ?? const <HomeTab>[];
    if (configured.isNotEmpty) {
      setState(() {
        _tabs = configured;
        _tab = configured.first;
      });
      unawaited(_load());
    } else {
      unawaited(_bootstrapTabs());
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onController);
    // Leaving the page: build the next first page for this tab so coming back
    // is instant and fresh.
    final tab = _tab;
    if (tab != null) _api?.prefetchFeed(channel: tab.channel);
    _openTimer?.cancel();
    _openWatchdog?.cancel();
    _pageController.dispose();
    _focusNode.dispose();
    unawaited(_pool.dispose());
    super.dispose();
  }

  /// Older gateways do not ship `home_tabs` in the UI manifest; ask the
  /// dedicated endpoint instead of inventing a default tab.
  Future<void> _bootstrapTabs() async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final tabs = await api.tabs();
      if (!mounted) return;
      if (tabs.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _tabs = tabs;
        _tab = tabs.first;
      });
      await _load();
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final api = AppScope.controllerOf(context).sourceApi;
    final tab = _tab;
    if (api == null || tab == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    final epoch = ++_epoch;
    // A card that was opening belongs to the previous tab; its completion
    // must not start playing over the new one.
    _openToken++;
    _preloadGeneration++;
    unawaited(_pool.pauseAll());
    _pool.forgetPreloads();
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      // The previous tab's cards stay on screen until the new page arrives:
      // blanking to black and showing a spinner made every switch feel like
      // a fresh launch, even when the answer took 200 ms.
      _stats.clear();
      _plans.clear();
      _next = '';
      _index = 0;
      _needsLogin = false;
    });
    try {
      final page = await api.feed(channel: tab.channel, limit: _pageSize);
      if (!mounted || epoch != _epoch) return;
      var items = page.items;
      var next = page.next;
      final tag = _categoryTagFor(tab);
      if (next.isEmpty && tag.isNotEmpty) {
        // The tab's cell is a short list: top it up from its category.
        try {
          final more = await api.category(tag: tag, limit: 20);
          if (!mounted || epoch != _epoch) return;
          final seen = items.map((item) => item.id).toSet();
          items = [...items, ...more.items.where((i) => !seen.contains(i.id))];
          next = more.next;
          _categoryFallback = true;
          _categoryTag = tag;
        } on Object {
          // Keep the tab's own page when the category fails.
        }
      }
      setState(() {
        _items = items;
        _next = next;
        _loading = false;
      });
      if (_items.isEmpty) return;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      _openAt(0);
      _loadStats(0);
      _prefetchPlans(0);
      // Pull pages right away so the session starts with ~20 cards and their
      // play plans decrypted, instead of waiting for a swipe.
      _fillStartup();
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      if (error is SpException && error.code == SpErrorCode.unauthorized) {
        setState(() {
          _needsLogin = true;
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  Future<void> _fillStartup() async {
    for (var i = 0; i < 3; i++) {
      if (!mounted || _items.length >= 20 || _next.isEmpty) break;
      await _loadMore();
    }
    // Warm the other tabs only after the visible feed is complete, so their
    // page builds do not compete with the first two pages.
    if (mounted) _prefetchOtherTabs();
  }

  /// Category tag that can extend a short home tab, supplied by the source.
  String _categoryTagFor(HomeTab tab) => tab.categoryTag;

  Future<void> _loadMore() async {
    final api = AppScope.controllerOf(context).sourceApi;
    final tab = _tab;
    if (api == null || tab == null || _loadingMore) return;
    final tag = _categoryTagFor(tab);
    // A short home tab ends after a few cards; once its cursor is empty the
    // feed continues from the category the source attached to it, so the
    // viewer never reaches a dead end.
    final extend = _next.isEmpty && tag.isNotEmpty && !_categoryFallback;
    if (_next.isEmpty && !extend) return;
    if (extend) {
      _categoryFallback = true;
      _categoryTag = tag;
    }
    final epoch = _epoch;
    setState(() => _loadingMore = true);
    try {
      final page = _categoryFallback
          ? await api.category(
              tag: _categoryTag,
              cursor: extend ? '' : _next,
              limit: _pageSize,
            )
          : await api.feed(
              channel: tab.channel,
              cursor: _next,
              limit: _pageSize,
            );
      if (!mounted) return;
      if (epoch != _epoch) {
        // A newer listing owns the screen: this response must not leave the
        // pagination flag stuck for it.
        setState(() => _loadingMore = false);
        return;
      }
      final seen = _items.map((item) => item.id).toSet();
      final extra = page.items.where((item) => !seen.contains(item.id)).toList();
      final next = page.next;
      setState(() {
        _items = [..._items, ...extra];
        _next = next;
        _loadingMore = false;
      });
      // Warm the plans of the newly appended tail so the next swipes are
      // instant instead of waiting on multi_video_model.
      _prefetchPlans(_index);
      // Still close to the tail after this page: pull the next one now so the
      // buffer never thins out mid-scroll.
      if (_items.length - _index <= 10 && _next.isNotEmpty) {
        unawaited(_loadMore());
      }
    } on Object {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// Resolves the episode id for one card. Feed rows carry the featured vid;
  /// sources without it fall back to the first episode.
  Future<String> _episodeIdOf(SourceApi api, Item item) async {
    final rawVid = item.extra['vid'];
    if (rawVid is String && rawVid.isNotEmpty) return rawVid;
    try {
      final episodes = await api.episodes(item.id);
      if (episodes.episodes.isNotEmpty) return episodes.episodes.first.id;
    } on Object {
      // Sources without episode support play the item directly.
    }
    return '';
  }

  /// 设置 → 默认播放画质; 'auto' lets the gateway pick.
  String get _qualityPref {
    final quality = AppScope.controllerOf(context).settings.defaultQuality;
    return quality == Quality.auto || quality.isEmpty ? 'auto' : quality;
  }

  Future<MediaPlan> _planFor(SourceApi api, Item item) async {
    var plan = _plans[item.id];
    if (plan != null) return plan;
    final episodeId = await _episodeIdOf(api, item);
    plan = await api.play(PlayRequest(
      itemId: item.id,
      episodeId: episodeId,
      quality: _qualityPref,
    ));
    _plans[item.id] = plan;
    return plan;
  }

  Future<void> _openAt(int index) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null || index < 0 || index >= _items.length) return;
    final item = _items[index];
    final token = ++_openToken;
    _openWatchdog?.cancel();

    final leaving = _playingId;
    if (leaving != null && leaving != item.id) {
      final pos = _engine.snapshot.value.position;
      if (pos > const Duration(seconds: 3)) _resume[leaving] = pos;
    }

    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final plan = await _planFor(api, item);
      if (!mounted || token != _openToken) return;
      // A preloaded neighbour starts instantly; anything else opens here.
      final adopted = await _pool.adopt(item.id);
      if (!mounted || token != _openToken) return;
      if (!adopted) {
        await _pool.openActive(item.id, plan);
        if (!mounted || token != _openToken) return;
        await _engine.play();
        if (!mounted || token != _openToken) return;
      }
      _playingEpisodeId = plan.episodeId;
      _playingId = item.id;
      _retryIndex = -1;
      // A broken upstream file can sit at position 0 forever; the watchdog
      // retries once and then reports instead of buffering indefinitely.
      _openWatchdog?.cancel();
      _openWatchdog = Timer(const Duration(seconds: 10), () {
        if (!mounted || token != _openToken) return;
        final snapshot = _engine.snapshot.value;
        if (snapshot.position > Duration.zero || snapshot.error != null) return;
        if (_retryIndex != index) {
          _retryIndex = index;
          _openAt(index);
        } else {
          setState(() {
            _error = '视频加载超时，可能是源文件无法播放';
            _opening = false;
          });
        }
      });
      final resume = _resume[item.id];
      if (resume != null) unawaited(_seekResume(resume));
      setState(() => _opening = false);
      _prefetchPlans(index);
      _preloadStreams(index);
      _loadStats(index);
    } on Object catch (error) {
      if (!mounted || token != _openToken) return;
      // One quiet retry: several streams opening at once can starve the
      // request that matters, and a transient failure should not end up as
      // an error card in the middle of the feed.
      if (_retryIndex != index) {
        _retryIndex = index;
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (mounted && token == _openToken) {
          await _openAt(index);
        }
        return;
      }
      setState(() {
        _error = describeGatewayError(error);
        _opening = false;
      });
    }
  }

  /// Warms the gateway for the next few cards: /play prepares moov and the
  /// vault pre-decrypts the head, so swiping to them costs no upstream round
  /// trip.
  void _prefetchPlans(int index) {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) return;
    for (var i = index + 1; i <= index + 10 && i < _items.length; i++) {
      final item = _items[i];
      if (_plans.containsKey(item.id) || !_warming.add(item.id)) continue;
      _planFor(api, item).catchError((Object _) {
        _warming.remove(item.id);
        return const MediaPlan();
      });
    }
  }

  /// Opens the next cards in the spare engines, paused. The plan call is
  /// already cached by [_prefetchPlans], so this is only the stream itself.
  Future<void> _preloadStreams(int index) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) return;
    final generation = ++_preloadGeneration;
    // Let the visible card start first: opening four streams at once can
    // starve its /play call.
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (mounted &&
        generation == _preloadGeneration &&
        !_engine.snapshot.value.playing &&
        _engine.snapshot.value.error == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted ||
        generation != _preloadGeneration ||
        _engine.snapshot.value.error != null) {
      return;
    }
    for (var i = index + 1; i <= index + _preloadAhead && i < _items.length; i++) {
      final item = _items[i];
      try {
        final plan = await _planFor(api, item);
        if (!mounted || generation != _preloadGeneration) return;
        await _pool.preload(item.id, plan);
      } on Object {
        // Preloading is best-effort.
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || generation != _preloadGeneration) return;
    }
  }

  /// media_kit ignores a seek issued before the container knows its duration,
  /// so wait briefly and keep the target off the very end.
  Future<void> _seekResume(Duration target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    var duration = _engine.snapshot.value.duration;
    while (duration <= Duration.zero && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      duration = _engine.snapshot.value.duration;
    }
    var position = target;
    if (duration > const Duration(seconds: 3) &&
        position > duration - const Duration(seconds: 3)) {
      position = duration - const Duration(seconds: 3);
    }
    if (position > Duration.zero) await _engine.seek(position);
  }

  void _loadStats(int index) {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null || index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (_stats.containsKey(item.id)) return;
    final vid = item.extra['vid'] is String ? item.extra['vid'] as String : '';
    api.stats([item.id], vid: vid).then((value) {
      if (!mounted || value.isEmpty) return;
      setState(() => _stats.addAll(value));
    }).catchError((Object _) {});
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    _loadStats(index);
    // Fast swiping should not load every card it passes: wait until the user
    // settles on one, then open that stream only.
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted) _openAt(index);
    });
    // Keep at least ten cards ahead. The upstream pages hold ~10 items, so
    // waiting for the halfway mark made the next page arrive just as the
    // viewer reached the end.
    if (_items.isNotEmpty && index >= _items.length - 10) {
      _loadMore();
    }
    // Warm the next few while this one plays.
    _prefetchPlans(index);
  }

  /// Keep the tabs we are not watching ready, so the first visit to any of
  /// them is instant even if its slot was consumed earlier.
  void _prefetchOtherTabs() {
    final api = AppScope.controllerOf(context).sourceApi;
    final current = _tab;
    if (api == null || current == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final tab in _tabs) {
      if (tab.channel == current.channel) continue;
      final last = _prefetchedAt[tab.channel] ?? 0;
      if (now - last < 120000) continue;
      _prefetchedAt[tab.channel] = now;
      api.prefetchFeed(channel: tab.channel);
    }
  }

  void _switchTab(HomeTab tab) {
    final previous = _tab;
    if (previous == null || tab.channel == previous.channel) return;
    _categoryFallback = false;
    _categoryTag = '';
    setState(() => _tab = tab);
    _load();
    // The tab we just left prebuilds its next first page while the user
    // watches this one.
    AppScope.controllerOf(context)
        .sourceApi
        ?.prefetchFeed(channel: previous.channel);
  }

  Future<void> _togglePlay() async {
    final snapshot = _engine.snapshot.value;
    if (snapshot.playing) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  void _jump(int delta) {
    final next = (_index + delta).clamp(0, _items.length - 1);
    if (next == _index) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// One mouse-wheel notch = one video. PageView's own scroll physics needs a
  /// large delta, which is why the wheel used to require several ticks.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy.abs() < 1) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWheelMs < 220) return;
    _lastWheelMs = now;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _jump(dy > 0 ? 1 : -1);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _jump(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _jump(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openFull(Item item) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) return;
    // The feed is already playing; pause it so the full player never becomes a
    // second audio source, and hand its exact position over.
    final feedEpisodeId = _playingEpisodeId;
    final feedPosition = _engine.snapshot.value.position;
    try {
      final episodePage = await api.episodes(item.id);
      if (!mounted) return;
      final episodes = episodePage.episodes;
      final rawVid = item.extra['vid'];
      var first = episodes.isEmpty
          ? null
          : episodes.firstWhere(
              (episode) => episode.id == rawVid,
              orElse: () => episodes.first,
            );
      // Continue where the user stopped: the history record wins over the
      // featured episode when it belongs to this series.
      final seriesKey = '${api.sourceId}:${item.id}';
      final history = await AppScope.of(context).library.history();
      for (final record in history) {
        if (record.seriesKey != seriesKey || record.episodeId.isEmpty) continue;
        for (final episode in episodes) {
          if (episode.id == record.episodeId) {
            first = episode;
            break;
          }
        }
        break;
      }
      final plan = first != null && first.id == rawVid
          ? await _planFor(api, item)
          : await api.play(
              PlayRequest(
                itemId: item.id,
                episodeId: first?.id ?? '',
                quality: _qualityPref,
              ),
            );
      if (!mounted) return;
      final startEpisode = first?.id ?? plan.episodeId;
      await _engine.pause();
      final exit = await openFullPlayer(
        context,
        plan: plan,
        title: item.title,
        api: api,
        itemId: item.id,
        episodes: episodes,
        episodeId: startEpisode,
        cover: item.cover,
        initialPosition:
            startEpisode == feedEpisodeId ? feedPosition : Duration.zero,
      );
      if (!mounted) return;
      if (exit?.wantsDetail == true) {
        // The player is already gone; show the detail page inside the shell
        // (not above it) and leave the feed paused behind it.
        try {
          final shown = await api.detail(exit!.itemId);
          if (mounted) {
            await openDetail(context, api, shown, poster: exit.cover);
          }
        } on Object {
          // Fall back to the card the feed opened.
          if (mounted) await openDetail(context, api, item);
        }
        if (!mounted) return;
        await _resumeFeedAfterPlayer(api, item, feedEpisodeId, feedPosition);
        return;
      }
      _focusNode.requestFocus();
      await _resumeFeedAfterPlayer(api, item, feedEpisodeId, feedPosition);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeGatewayError(error))),
      );
    }
  }

  /// After the full player closes, continue the feed where the player left
  /// off (including a different episode) so the hand-off is seamless.
  Future<void> _resumeFeedAfterPlayer(
    SourceApi api,
    Item item,
    String fallbackEpisodeId,
    Duration fallbackPosition,
  ) async {
    var episodeId = fallbackEpisodeId;
    var position = fallbackPosition;
    try {
      final key = '${api.sourceId}:${item.id}';
      final history = await AppScope.of(context).library.history();
      for (final record in history) {
        if (record.seriesKey != key || record.episodeId.isEmpty) continue;
        episodeId = record.episodeId;
        position = Duration(seconds: record.positionSec);
        break;
      }
    } on Object {
      // Fall back to the state captured before the player opened.
    }
    if (!mounted) return;
    try {
      if (episodeId.isNotEmpty && episodeId != _playingEpisodeId) {
        final plan = await api.play(
          PlayRequest(itemId: item.id, episodeId: episodeId),
        );
        if (!mounted) return;
        await _engine.open(plan);
        _playingEpisodeId = episodeId;
      }
      if (position > Duration.zero) await _seekWhenReady(position);
      await _engine.play();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = describeGatewayError(error));
    }
  }

  Future<void> _seekWhenReady(Duration target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (_engine.snapshot.value.duration > Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted) return;
    await _engine.seek(target);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controllerOf(context);
    final api = controller.sourceApi;
    final title = api?.manifest.name ?? AppStrings.appName;
    final labels = controller.uiManifest?.labels ?? const <String, String>{};
    final tab = _tab;
    final tokens = AppTokens.of(context);

    if (_loading && _items.isEmpty) {
      return PageTitleBinding(
        title: title,
        child: const ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (tab == null) {
      return PageTitleBinding(
        title: title,
        child: const StatePanel(
          icon: Icons.live_tv_outlined,
          title: AppStrings.emptyTitle,
          body: AppStrings.emptyBody,
        ),
      );
    }
    if (_items.isEmpty) {
      final needsLogin = _needsLogin || tab.requiresAuth;
      return PageTitleBinding(
        title: tab.title,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            StatePanel(
              icon: needsLogin
                  ? Icons.person_outline
                  : Icons.movie_outlined,
              title: needsLogin
                  ? (labels['home.login_required_title'] ?? '需要登录')
                  : AppStrings.emptyTitle,
              body: needsLogin
                  ? (labels['home.login_required_body'] ??
                      '登录后查看这里的内容。')
                  : AppStrings.emptyBody,
              action: needsLogin
                  ? FilledButton(
                      onPressed: () async {
                        final api =
                            AppScope.controllerOf(context).sourceApi;
                        if (api == null) return;
                        final ok =
                            await showLoginSheet(context, api: api);
                        if (ok && mounted) _load();
                      },
                      child: Text(labels['home.login_action'] ??
                          AppStrings.login),
                    )
                  : null,
            ),
            FeedGlassTabs(
              tabs: _tabs,
              current: tab,
              onSelect: _switchTab,
            ),
          ],
        ),
      );
    }

    return PageTitleBinding(
      title: tab.title,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ScrollConfiguration(
          behavior: const FeedScrollBehavior(),
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: Colors.black,
                  child: _engine.buildSurface(context),
                ),
                // A refresh keeps the current cards; a hairline says work is
                // running without taking the picture away.
                if (_loading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                // A slow switch would otherwise keep the previous card's
                // picture (or a black frame) under the new title.
                if (_items.isNotEmpty)
                  Positioned.fill(
                    child: ValueListenableBuilder<PlaybackSnapshot>(
                      valueListenable: _engine.snapshot,
                      builder: (context, snapshot, _) {
                        // A stalled stream shows a black surface; keep the
                        // artwork over it while mpv is buffering again.
                        final ready = snapshot.position > Duration.zero &&
                            snapshot.error == null &&
                            !snapshot.buffering;
                        if (ready && !_opening) {
                          return const SizedBox.shrink();
                        }
                        return _FeedSwitchCurtain(
                          cover: _items[_index].cover,
                          title: _items[_index].title,
                        );
                      },
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity < -120) {
                      _jump(1);
                    } else if (velocity > 120) {
                      _jump(-1);
                    }
                  },
                  child: PageView.builder(
                  key: ValueKey('feed-$_epoch'),
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  scrollDirection: Axis.vertical,
                  itemCount: _items.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final rawVid = item.extra['vid'];
                    return FeedOverlay(
                      item: item,
                      stats: _stats[item.id],
                      api: api,
                      // 剧评 and 弹幕 are keyed by the episode vid; fall back
                      // to the row's featured vid before playback resolves.
                      episodeId: index == _index && _playingEpisodeId.isNotEmpty
                          ? _playingEpisodeId
                          : (rawVid is String ? rawVid : ''),
                      onTap: _togglePlay,
                      onOpenFull: () => _openFull(item),
                      onScrollSignal: _onPointerSignal,
                      labels: AppScope.controllerOf(context)
                              .uiManifest
                              ?.labels ??
                          const {},
                    );
                  },
                  ),
                ),
                FeedGlassTabs(
                  tabs: _tabs,
                  current: tab,
                  onSelect: _switchTab,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: ValueListenableBuilder<PlaybackSnapshot>(
                        valueListenable: _engine.snapshot,
                        builder: (context, snapshot, _) {
                          if (snapshot.ready &&
                              !snapshot.playing &&
                              snapshot.error == null) {
                            return const FeedPauseBadge();
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<PlaybackSnapshot>(
                  valueListenable: _engine.snapshot,
                  builder: (context, snapshot, _) {
                    final show = _opening ||
                        (snapshot.buffering && snapshot.error == null);
                    if (!show) return const SizedBox.shrink();
                    return const Positioned.fill(
                      child: IgnorePointer(child: FeedLoading()),
                    );
                  },
                ),
                if (_error != null)
                  FeedError(
                    message: _error!,
                    onRetry: () => _openAt(_index),
                  )
                // Engine failures (missing decryptor, undecodable stream) land
                // on the snapshot, not in a catch: without this the feed just
                // sits on the cover and looks broken.
                else
                  ValueListenableBuilder<PlaybackSnapshot>(
                    valueListenable: _engine.snapshot,
                    builder: (context, snapshot, _) {
                      final error = snapshot.error;
                      if (error == null || error.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return FeedError(
                        message: error,
                        onRetry: () => _openAt(_index),
                      );
                    },
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: FeedProgress(engine: _engine, colors: tokens.colors),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted top navigation. Sits above the PageView so a tap on a tab never
/// falls through to the video.


/// Opaque cover used while a stream is opening, so the engine's previous
/// frame never shows under the new card.
class _FeedSwitchCurtain extends StatelessWidget {
  const _FeedSwitchCurtain({required this.cover, required this.title});

  final String cover;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover.isNotEmpty)
          CoverImage(
            url: cover,
            seed: title,
            fit: BoxFit.cover,
            decodeWidth: 240,
            blurSigma: 26,
          ),
        const ColoredBox(color: Color(0xB3000000)),
        const Center(child: LoadingMark()),
      ],
    );
  }
}
