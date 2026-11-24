import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../decryptor/decrypt_proxy.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../logging/app_log.dart';
import '../platform/platform.dart';
import '../player/bvc2_playback_engine.dart';
import '../player/playback_engine.dart';
import '../player/playback_pool.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import '../sp/quality.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
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

class _FeedCacheEntry {
  _FeedCacheEntry(this.items, this.next, this.at);

  final List<Item> items;
  final String next;
  final DateTime at;
}

/// The feed as the viewer left it. This lives in memory across sidebar pages,
/// so coming back from 搜索/排行榜 does not reload the list or warm anything;
/// only tapping the active 推荐 tab starts a fresh load.
class _FeedSession {
  _FeedSession(this.channel, this.items, this.next, this.index, this.at);

  final String channel;
  final List<Item> items;
  final String next;
  final int index;
  final DateTime at;
}

class _HomeFeedPageState extends State<HomeFeedPage> {
  static const _pageSize = 20;
  // Reopening a source used to start from a blank spinner until the gateway
  // answered. The last first page is metadata only and is shown immediately
  // while the fresh one loads.
  static final Map<String, _FeedCacheEntry> _feedCache = {};
  static final Map<String, _FeedSession> _sessions = {};

  // The active card plus N neighbours, opened paused. N comes from
  // 设置 → 预加载数量.
  late final PlaybackPool _pool;
  late final int _preloadAhead;

  PlaybackEngine get _engine => _pool.active;

  PageController _pageController = PageController();
  final FocusNode _focusNode = FocusNode();

  // Tabs are source data, never shell defaults: the UI manifest carries them.
  List<HomeTab> _tabs = const [];
  HomeTab? _tab;

  List<Item> _items = const [];
  String _itemsKey = '';
  final Map<String, ItemStats> _stats = {};
  final Map<String, MediaPlan> _plans = {};
  final Set<String> _warming = {};

  int _index = 0;
  // The page the wheel burst is heading for. _index only updates when the
  // animation lands, so rapid notches used to all target the same page and a
  // five-notch flick advanced two videos.
  int? _jumpTarget;
  String _playingEpisodeId = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _opening = false;
  // True once the shared engine has painted a feed frame. Swipes after that
  // keep the old picture and switch underneath it instead of showing a cover
  // and spinner for every card.
  bool _hadFrame = false;
  /// Timestamp of the last card open, used to log the wait for its first
  /// decoded frame (the moment the loading curtain actually disappears).
  DateTime? _openWaitingSince;
  bool _started = false;
  bool _deferredForCore = false;
  String? _error;
  String _next = '';
  // Playback position per feed card: swiping away and back must resume where
  // the viewer left, not restart the drama.
  String? _playingId;
  final Map<String, Duration> _resume = {};
  bool _needsLogin = false;
  // The feed starts with sound, but the top-right control must be able to
  // silence it without entering the full player. The choice follows card
  // changes because preloaded engines open at 100%.
  bool _muted = false;
  SourceApi? _api;
  Timer? _openTimer;
  int _openToken = 0;
  int _epoch = 0;
  int _lastWheelMs = 0;
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
    // The stored core gateway still carries the previous session's port until
    // attachLocalCore replaces it. Starting the feed now would spend the
    // request timeout on a port nothing is listening on.
    if (controller.coreStarting && controller.activeSourceIsCore) {
      _deferredForCore = true;
      return;
    }
    _beginFeedLoad(controller);
  }

  void _beginFeedLoad(AppController controller) {
    _api = controller.sourceApi;
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

  /// The source can arrive after the first paint: the bundled core starts in
  /// the background, so the page is built while [sourceApi] is still null.
  /// Once it appears, load the feed instead of leaving the empty state.
  void _onController() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    // The shell replaces this page when the source changes; do not start a
    // second feed request from the page that is already on its way out.
    if (widget.ctx.sourceId.isNotEmpty &&
        controller.activeSourceId != widget.ctx.sourceId) {
      return;
    }
    if (controller.coreStarting) return;
    if (_deferredForCore) {
      _deferredForCore = false;
      _beginFeedLoad(controller);
      return;
    }
    final api = controller.sourceApi;
    if (api == null || identical(api, _api)) return;
    _beginFeedLoad(controller);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onController);
    // Remember the list for the return trip. Switching to 搜索/排行榜 must not
    // reload or prefetch the feed; tapping the active 推荐 tab is the only
    // thing that refreshes it.
    final tab = _tab;
    final api = _api;
    if (tab != null && api != null && _items.isNotEmpty) {
      _sessions[api.sourceId] = _FeedSession(
        tab.channel,
        List<Item>.unmodifiable(_items),
        _next,
        _index,
        DateTime.now(),
      );
    }
    _openTimer?.cancel();
    _openWatchdog?.cancel();
    _moreTimer?.cancel();
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
      // Returning from another sidebar page: reopen the tab the viewer left,
      // not always 推荐.
      final session = _sessions[api.sourceId];
      var selected = tabs.first;
      if (session != null) {
        for (final tab in tabs) {
          if (tab.channel == session.channel) {
            selected = tab;
            break;
          }
        }
      }
      setState(() {
        _tabs = tabs;
        _tab = selected;
      });
      await _load();
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load({bool force = false}) async {
    final api = AppScope.controllerOf(context).sourceApi;
    final tab = _tab;
    if (api == null || tab == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    // A return from another sidebar page restores the list in memory; only a
    // tap on the active 推荐 tab (force) asks the gateway for fresh cards.
    final session = force ? null : _sessions[api.sourceId];
    final restored = session != null &&
            session.channel == tab.channel &&
            DateTime.now().difference(session.at) <
                const Duration(minutes: 30) &&
            session.items.isNotEmpty
        ? session
        : null;
    final loadStarted = DateTime.now();
    final epoch = ++_epoch;
    final cacheKey = '${api.sourceId}|${tab.channel}';
    final cached = _feedCache[cacheKey];
    final reuseCached = restored == null &&
        cached != null &&
        _itemsKey != cacheKey &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 5);
    final target = restored == null
        ? 0
        : restored.index.clamp(0, restored.items.length - 1);
    if (restored != null) {
      if (!_pageController.hasClients) {
        _pageController.dispose();
        _pageController = PageController(initialPage: target);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(target);
          }
        });
      }
    }
    // A card that was opening belongs to the previous tab; its completion
    // must not start playing over the new one. Likewise, cancel any plan
    // warm-up chain still running for the old list.
    _openToken++;
    _planPrefetchToken++;
    _warmCursor = 0;
    _moreTimer?.cancel();
    _moreAttempt = 0;
    _warming.clear();
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
      _index = target;
      _jumpTarget = restored == null ? null : target;
      _needsLogin = false;
      if (restored != null) {
        _items = restored.items;
        _next = restored.next;
        _itemsKey = cacheKey;
        _loading = false;
      } else if (reuseCached) {
        _items = cached.items;
        _next = cached.next;
        _itemsKey = cacheKey;
      } else {
        _next = '';
      }
    });
    if (restored != null) {
      AppLog.write(
          'feed ${tab.channel} restore n=${_items.length} at=$target');
      unawaited(() async {
        await _pool.pauseAll();
        if (!mounted || epoch != _epoch) return;
        _openAt(target);
        _loadStats(target);
        _scheduleWarm();
      }());
      return;
    }
    AppLog.write('feed ${tab.channel} start cache=$reuseCached');
    if (reuseCached && _items.isNotEmpty) {
      // Start the cached first card while the fresh page is in flight; the
      // network response usually confirms the same card and does not reopen
      // it again. Wait for the outgoing stream to pause first, otherwise its
      // late pause can land on the new one.
      unawaited(() async {
        await _pool.pauseAll();
        if (!mounted || epoch != _epoch) return;
        _openAt(0);
        _loadStats(0);
      }());
    }
    try {
      final page = await api.feed(
        channel: tab.channel,
        limit: _pageSize,
        refresh: force,
      );
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
        _itemsKey = cacheKey;
        _loading = false;
      });
      AppLog.write('feed ${tab.channel} page n=${items.length} '
          '${DateTime.now().difference(loadStarted).inMilliseconds}ms');
      if (items.isNotEmpty) {
        _feedCache[cacheKey] = _FeedCacheEntry(
          items,
          next,
          DateTime.now(),
        );
        while (_feedCache.length > 12) {
          _feedCache.remove(_feedCache.keys.first);
        }
      }
      if (_items.isEmpty) return;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      _jumpTarget = 0;
      if (!_opening) {
        if (_playingId != _items.first.id) {
          _openAt(0);
        } else if (force) {
          // The fresh page still starts with the card on screen; restart it
          // so tapping 推荐 has a visible effect.
          unawaited(_engine.seek(Duration.zero));
          unawaited(_engine.play());
        }
      }
      _loadStats(0);
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
        // A cached page stays usable when the refresh fails; do not put an
        // error panel over a feed the viewer can still browse.
        _error = _items.isEmpty ? describeGatewayError(error) : null;
        _loading = false;
      });
    }
  }

  Future<void> _fillStartup() async {
    final epoch = _epoch;
    // The first upstream page is only a handful of cards and each following
    // page is slow. Fill a real buffer in the background while the viewer is
    // still on the first card, instead of waiting for the swipe to reach the
    // end of the list (which is what showed 加载中 after a few swipes).
    // Let the first card finish opening before pulling more pages; those
    // requests compete with the plan and media of the video the viewer is
    // opening right now.
    final startDeadline = DateTime.now().add(const Duration(seconds: 4));
    while (mounted && !_hadFrame && DateTime.now().isBefore(startDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (var page = 0;
        page < 3 &&
            mounted &&
            epoch == _epoch &&
            _items.length < 18 &&
            _next.isNotEmpty;
        page++) {
      // _loadMore may already be filling the tail (the page-change path).
      var waited = 0;
      while (mounted && _loadingMore && waited < 15000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waited += 100;
      }
      if (!mounted ||
          epoch != _epoch ||
          _items.length >= 18 ||
          _next.isEmpty) {
        break;
      }
      final started = DateTime.now();
      await _loadMore();
      AppLog.write('feed fill page $page n=${_items.length} '
          '${DateTime.now().difference(started).inMilliseconds}ms');
    }
  }

  /// Category tag that can extend a short home tab, supplied by the source.
  String _categoryTagFor(HomeTab tab) => tab.categoryTag;

  // A page request can take 24 s and still time out; without these the list
  // just stopped at the last card and the viewer could not scroll any further.
  Timer? _moreTimer;
  int _moreAttempt = 0;
  bool _moreWaiting = false;

  void _scheduleMoreRetry() {
    _moreTimer?.cancel();
    const delays = [2, 4, 8, 15];
    final seconds = delays[_moreAttempt < delays.length ? _moreAttempt : 3];
    _moreAttempt++;
    AppLog.write('feed more retry in ${seconds}s (attempt $_moreAttempt)');
    _moreTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || !_moreWaiting) return;
      setState(() => _moreWaiting = false);
      _loadMore();
    });
  }

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
      _moreTimer?.cancel();
      _moreAttempt = 0;
      _moreWaiting = false;
      setState(() {
        _items = [..._items, ...extra];
        _next = next;
        _loadingMore = false;
      });
      // Warm the plans of the newly appended tail so the next swipes are
      // instant instead of waiting on multi_video_model.
      _scheduleWarm();
      // Still close to the tail after this page: pull the next one now so the
      // buffer never thins out mid-scroll.
      if (_items.length - _index <= 10 && _next.isNotEmpty) {
        unawaited(_loadMore());
      }
    } on Object catch (error) {
      if (!mounted) return;
      final retry = _next.isNotEmpty && _items.length - _index <= 12;
      setState(() {
        _loadingMore = false;
        _moreWaiting = retry;
      });
      AppLog.write('feed more failed: ${describeGatewayError(error)}');
      if (retry) _scheduleMoreRetry();
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

  // Plans that are still being fetched. The prefetcher warms the next card
  // while the viewer may swipe onto it; both must await one request instead of
  // asking upstream for the same episode twice (the duplicate ran 9-13 s and
  // made the card the viewer was opening wait for its own prefetch).
  final Map<String, Future<MediaPlan>> _planPending = {};

  Future<MediaPlan> _planFor(
    SourceApi api,
    Item item, {
    bool transcode = true,
    bool skipWarm = false,
    bool preview = false,
  }) {
    // Feed previews and the full player need different copies of a bytevc2
    // episode (lossless VVC vs H.264), so they cannot share one cache slot.
    final key = '${item.id}|${transcode ? 'h264' : 'vvc'}';
    final cached = _plans[key];
    if (cached != null) return Future.value(cached);
    final pending = _planPending[key];
    if (pending != null) return pending;
    final future = _fetchPlan(
      api,
      item,
      key,
      transcode: transcode,
      skipWarm: skipWarm,
      preview: preview,
    );
    _planPending[key] = future;
    future.then<void>(
      (_) => _settlePlan(key, future),
      onError: (Object _, StackTrace __) => _settlePlan(key, future),
    );
    return future;
  }

  void _settlePlan(String key, Future<MediaPlan> future) {
    if (identical(_planPending[key], future)) _planPending.remove(key);
  }

  Future<MediaPlan> _fetchPlan(
    SourceApi api,
    Item item,
    String key, {
    required bool transcode,
    required bool skipWarm,
    required bool preview,
  }) async {
    final episodeId = await _episodeIdOf(api, item);
    final plan = await api.play(PlayRequest(
      itemId: item.id,
      episodeId: episodeId,
      quality: _qualityPref,
      transcode: transcode,
      skipWarm: skipWarm,
      preview: preview,
    ));
    _plans[key] = plan;
    return plan;
  }

  /// The feed only owns the screen while its content route is on top. A
  /// detail page can be pushed while a plan is still loading; starting the
  /// stream then would play audio underneath the new page.
  bool get _feedVisible {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  Future<void> _openAt(int index) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null || index < 0 || index >= _items.length) return;
    final item = _items[index];
    final openStarted = DateTime.now();
    final token = ++_openToken;
    _openWatchdog?.cancel();

    final leaving = _playingId;
    if (leaving != null && leaving != item.id) {
      final pos = _engine.position.value;
      if (pos > const Duration(seconds: 3)) _resume[leaving] = pos;
    }

    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      // The feed is a preview strip: it swipes through many works, so play
      // the lossless VVC copy here and leave the H.264 rebuild to the full
      // player. Transcoding every card was the main CPU cost of browsing.
      final planStarted = DateTime.now();
      final plan = await _planFor(api, item, transcode: false, preview: true);
      final planMs = DateTime.now().difference(planStarted).inMilliseconds;
      if (planMs >= 300) {
        AppLog.write('feed plan ${item.id} ${planMs}ms');
      }
      if (!mounted || token != _openToken) return;
      // This card has its plan: start the next one now, not when the viewer
      // swipes. The playlist entry then has seconds to buffer its media.
      _scheduleWarm();
      if (!_feedVisible) {
        // A page was opened over the feed while the plan was loading.
        setState(() => _opening = false);
        return;
      }
      // The prefetcher puts the next card in libmpv's playlist. If this is
      // that card, jump within the existing pipeline instead of reopening.
      var advanced = plan.episodeId.isNotEmpty &&
          await _engine.playQueuedNext(plan.episodeId);
      if (!mounted || token != _openToken) return;
      if (!advanced && _hadFrame && plan.episodeId.isNotEmpty) {
        // A fast swipe can beat the prefetcher. Append the card and jump in
        // the playlist instead of reopening the player and blanking the
        // surface.
        await _engine.queueNext(plan);
        advanced = await _engine.playQueuedNext(plan.episodeId);
        if (!mounted || token != _openToken) return;
      }
      if (!advanced) {
        final adopted = await _pool.adopt(item.id);
        if (!mounted || token != _openToken) return;
        if (!adopted) {
          await _pool.openActive(item.id, plan);
          if (!mounted || token != _openToken) return;
          await _engine.play();
          if (!mounted || token != _openToken) return;
        }
      }
      _openWaitingSince = openStarted;
      _playingEpisodeId = plan.episodeId;
      _playingId = item.id;
      // A preloaded engine opens at 100%; reapply the feed's mute choice.
      unawaited(_applyFeedVolume());
      _retryIndex = -1;
      // A broken upstream file can sit at position 0 forever; the watchdog
      // retries once and then reports instead of buffering indefinitely.
      _openWatchdog?.cancel();
      _openWatchdog = Timer(const Duration(seconds: 10), () {
        if (!mounted || token != _openToken) return;
        final snapshot = _engine.snapshot.value;
        if (_engine.position.value > Duration.zero ||
            snapshot.error != null) {
          return;
        }
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
      // Plans for the following cards wait until this one has its first
      // frame; an upstream request for a card nobody has reached yet must not
      // delay the video being opened now.
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

  int _planPrefetchToken = 0;
  // One worker walks the list; the next index it still has to plan.
  int _warmCursor = 0;
  bool _warmRunning = false;
  bool _warmAgain = false;

  /// Asks the plan worker to run. A swipe must not restart the worker: with a
  /// 2.5-4 s plan and a 1.2 s gap between cards, restarting on every swipe
  /// meant the chain never got past the next card, so every second swipe
  /// waited for a fresh /play.
  void _scheduleWarm() {
    if (_warmRunning) {
      _warmAgain = true;
      return;
    }
    _warmRunning = true;
    unawaited(_warmLoop());
  }

  Future<void> _warmLoop() async {
    final token = _planPrefetchToken;
    final controller = AppScope.controllerOf(context);
    final api = controller.sourceApi;
    if (api == null) {
      _warmRunning = false;
      return;
    }
    // A short-video swipe burst covers five cards before the viewer stops to
    // watch one; the whole window has to be ready by then. Only the next two
    // carry media warm-up, the rest are plan-only.
    final local = controller.activeSourceRunsLocally;
    final ahead = local ? 5 : _preloadAhead;
    try {
      while (mounted && token == _planPrefetchToken) {
        if (_warmCursor < _index + 1) _warmCursor = _index + 1;
        if (_warmCursor > _index + ahead || _warmCursor >= _items.length) {
          return;
        }
        final i = _warmCursor;
        final item = _items[i];
        if (!_warming.add(item.id)) {
          _warmCursor++;
          continue;
        }
        try {
          final planStarted = DateTime.now();
          final plan = await _planFor(
            api,
            item,
            transcode: false,
            skipWarm: i > _index + 2,
            preview: true,
          );
          final planMs = DateTime.now().difference(planStarted).inMilliseconds;
          if (planMs >= 300) {
            AppLog.write('feed prefetch plan ${item.id} $planMs ms');
          }
          // Swiping to this card must not wait for the CDN round trips the
          // proxy does while locating moov.
          final stream = plan.bestStream;
          final decryption = stream?.decryption ?? plan.decryption;
          if (stream != null && Bvc2PlaybackEngine.handlesPlan(plan)) {
            Bvc2PlaybackEngine.warm(plan);
          } else if (stream != null &&
              decryption.required &&
              decryption.location == 'client' &&
              decryption.keyHex.isNotEmpty) {
            DecryptProxy.warm(stream.url, decryption.keyHex);
          }
          if (mounted && token == _planPrefetchToken && i == _index + 1) {
            // Queue it in libmpv's playlist so the swipe is a playlist jump,
            // not a teardown and reopen of the video output.
            await _engine.queueNext(plan);
          }
        } on Object {
          // Skip it here; opening the card retries on demand.
        } finally {
          _warming.remove(item.id);
        }
        _warmCursor++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      _warmRunning = false;
      if (_warmAgain) {
        _warmAgain = false;
        if (mounted) _scheduleWarm();
      }
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
    _jumpTarget = index;
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
  }

  void _switchTab(HomeTab tab) {
    final previous = _tab;
    if (previous == null) return;
    if (tab.channel == previous.channel) {
      // Tapping the active 推荐 tab asks for a fresh list. Other tabs keep
      // what they have: switching pages must not trigger a reload either.
      final api = AppScope.controllerOf(context).sourceApi;
      if (api == null || _tabs.isEmpty || tab.channel != _tabs.first.channel) {
        return;
      }
      AppLog.write('feed refresh ${tab.channel}');
      _sessions.remove(api.sourceId);
      _load(force: true);
      return;
    }
    AppLog.write('feed switch ${previous.channel} -> ${tab.channel}');
    _categoryFallback = false;
    _categoryTag = '';
    setState(() => _tab = tab);
    _load();
  }

  Future<void> _togglePlay() async {
    final snapshot = _engine.snapshot.value;
    if (snapshot.playing) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  Future<void> _applyFeedVolume() async {
    try {
      await _engine.setVolume(_muted ? 0 : 1);
    } on Object {
      // Volume is best-effort; the mute button still reflects the intent.
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    unawaited(_applyFeedVolume());
  }

  void _jump(int delta) {
    if (_items.isEmpty) return;
    final last = _items.length - 1;
    final base = _jumpTarget ?? _index;
    if (delta > 0 && base >= last) {
      // At the tail the next page has not arrived yet. Ask for it instead of
      // silently refusing to move, which looked like the feed had ended.
      if (_next.isNotEmpty) {
        if (_moreWaiting) {
          _moreTimer?.cancel();
          _moreWaiting = false;
        }
        _loadMore();
      }
      return;
    }
    final next = (base + delta).clamp(0, last);
    if (next == base) return;
    _jumpTarget = next;
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
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The caption is a link to the work. Pause the feed under the detail page
  /// and pick the episode/position back up when it closes.
  Future<void> _openDetailFromFeed(Item item) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) return;
    final episodeId = _playingEpisodeId;
    final position = _engine.position.value;
    await _engine.pause();
    if (!mounted) return;
    await openDetail(context, api, item);
    if (!mounted) return;
    await _resumeFeedAfterPlayer(api, item, episodeId, position);
  }

  Future<void> _openFull(Item item) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) return;
    // Stop warming feed cards: the full player prepares the next episode of
    // this work and must not queue behind four unrelated previews.
    _planPrefetchToken++;
    _warming.clear();
    // The feed is already playing; pause it so the full player never becomes a
    // second audio source, and hand its exact position over.
    final feedEpisodeId = _playingEpisodeId;
    final feedPosition = _engine.position.value;
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
      // The player and the feed share one engine now, and the player may have
      // opened another work entirely. Reopen this card instead of assuming
      // the engine still holds its stream.
      final plan = await api.play(
        PlayRequest(
          itemId: item.id,
          episodeId: episodeId,
          quality: _qualityPref,
        ),
      );
      if (!mounted || !_feedVisible) return;
      await _engine.open(plan);
      _playingEpisodeId =
          plan.episodeId.isNotEmpty ? plan.episodeId : episodeId;
      if (position > Duration.zero) await _seekWhenReady(position);
      await _engine.play();
      // The full player may have replaced the playlist; queue the next feed
      // card again so the first swipe after returning stays seamless.
      _scheduleWarm();
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
    // On wide windows the shell floats its navigation over the video; keep
    // the caption out from under it. Narrow windows use a drawer instead.
    final sidebarInset = MediaQuery.sizeOf(context).width >= AppSizes.drawerWidth
        ? AppSizes.sidebar
        : 0.0;
    // The window drag bar floats transparently over the feed; keep the tab
    // pill and the utility buttons below it. OS fullscreen has no bar, and
    // Android puts the shell's own top bar above the feed instead.
    final titleBarInset = controller.immersive
        ? 0.0
        : isMobilePlatform
            ? 0.0
            : AppSizes.titleBar;

    if (_loading && _items.isEmpty) {
      return PageTitleBinding(
        title: title,
        child: ColoredBox(
          color: Colors.black,
          child: Padding(
            padding: EdgeInsets.only(left: sidebarInset),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoadingMark(),
                  const SizedBox(height: AppSpacing.x3),
                  Text(
                    '正在打开 $title',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: AppFontSize.xs,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            Padding(
              padding: EdgeInsets.only(left: sidebarInset),
              child: StatePanel(
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
            ),
            FeedGlassTabs(
              tabs: _tabs,
              current: tab,
              onSelect: _switchTab,
              topInset: titleBarInset,
              leftInset: sidebarInset,
              refreshing: _loading && _items.isNotEmpty,
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
                  child: RepaintBoundary(
                    child: _engine.buildSurface(context),
                  ),
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
                    child: ListenableBuilder(
                      listenable: Listenable.merge(
                        [_engine.snapshot, _engine.position],
                      ),
                      builder: (context, _) {
                        // A stalled stream shows a black surface; keep the
                        // artwork over it while mpv is buffering again.
                        final snapshot = _engine.snapshot.value;
                        final ready = _engine.position.value >
                                Duration.zero &&
                            snapshot.error == null &&
                            !snapshot.buffering;
                        if (ready) {
                          final waiting = _openWaitingSince;
                          if (waiting != null) {
                            _openWaitingSince = null;
                            AppLog.write(
                              'feed frame ${_items[_index].id} '
                              '${DateTime.now().difference(waiting).inMilliseconds}ms',
                            );
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _scheduleWarm();
                            });
                          }
                          _hadFrame = true;
                          return const SizedBox.shrink();
                        }
                        // A later swipe keeps the previous frame until the
                        // new one paints; only the first card of this feed
                        // needs the full cover.
                        if (_hadFrame) return const SizedBox.shrink();
                        return _FeedSwitchCurtain(
                          cover: _items[_index].cover,
                          title: _items[_index].title,
                          leftInset: sidebarInset,
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
                      onOpenDetail: () => _openDetailFromFeed(item),
                      onScrollSignal: _onPointerSignal,
                      leftInset: sidebarInset,
                    );
                  },
                  ),
                ),
                FeedGlassTabs(
                  tabs: _tabs,
                  current: tab,
                  onSelect: _switchTab,
                  topInset: titleBarInset,
                  leftInset: sidebarInset,
                  refreshing: _loading && _items.isNotEmpty,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: EdgeInsets.only(left: sidebarInset),
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
                ),
                ValueListenableBuilder<PlaybackSnapshot>(
                  valueListenable: _engine.snapshot,
                  builder: (context, snapshot, _) {
                    final show = _opening ||
                        (snapshot.buffering && snapshot.error == null);
                    if (!show) return const SizedBox.shrink();
                    return Positioned.fill(
                      child: IgnorePointer(
                        child: DelayedVisible(
                          visible: show,
                          // A fast swipe must not flash a spinner; a stalled
                          // stream still shows one after this grace period.
                          delay: _hadFrame
                              ? const Duration(milliseconds: 2500)
                              : Duration.zero,
                          child: FeedLoading(leftInset: sidebarInset),
                        ),
                      ),
                    );
                  },
                ),
                if (_items.isNotEmpty &&
                    _index == _items.length - 1 &&
                    (_loadingMore || _moreWaiting))
                  Positioned(
                    left: sidebarInset,
                    right: 0,
                    bottom: 120,
                    child: const IgnorePointer(
                      child: Center(child: FeedMoreBadge()),
                    ),
                  ),
                if (_error != null)
                  FeedError(
                    message: _error!,
                    onRetry: () => _openAt(_index),
                    leftInset: sidebarInset,
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
                        leftInset: sidebarInset,
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
  const _FeedSwitchCurtain({
    required this.cover,
    required this.title,
    this.leftInset = 0,
  });

  final String cover;
  final String title;
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover.isNotEmpty)
          // No full-screen blur here: it ran while the next stream was
          // opening and cost more than the cover adds.
          CoverImage(
            url: cover,
            seed: title,
            fit: BoxFit.cover,
            decodeWidth: 240,
          ),
        const ColoredBox(color: Color(0xB3000000)),
        Padding(
          padding: EdgeInsets.only(left: leftInset),
          child: const Center(child: LoadingMark()),
        ),
      ],
    );
  }
}
