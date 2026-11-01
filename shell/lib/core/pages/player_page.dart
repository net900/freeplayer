import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../app/local_window_mode.dart';
import '../../l10n/strings.dart';
import '../decryptor/decrypt_proxy.dart';
import '../logging/app_log.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../library/local_library.dart';
import '../local/local_media.dart';
import '../local/local_thumbs.dart';
import '../local/sprite_thumb.dart';
import '../local/video_thumbs.dart';
import '../player/playback_coordinator.dart';
import '../player/playback_engine.dart';
import '../player/playback_pool.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import '../sp/page_types.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/cover_image.dart';
import '../window/window_controls.dart';
import 'common.dart';
import 'loading.dart';
import '../downloads/download_sheet.dart';
import 'login_sheet.dart';
import 'page_title.dart';
import 'player_danmaku_sheet.dart';
import 'player_overlays.dart';
import 'player_seek_bar.dart';
import 'player_sheets.dart';
import 'series_actions.dart';
import 'series_album.dart';

/// What the player reports when it closes. The player is a single route on the
/// root navigator; switching 作品系列 happens in place, so the result always
/// names the work that was on screen last.
class PlayerExit {
  const PlayerExit({
    this.wantsDetail = false,
    this.itemId = '',
    this.title = '',
    this.cover = '',
  });

  final bool wantsDetail;
  final String itemId;
  final String title;
  final String cover;
}

/// Pushes the player above the shell (root navigator) so there is no sidebar,
/// search box or top bar: the page is only the video plus its controls.
///
/// Completes with a [PlayerExit] when the player closed so the caller can show
/// the detail page: the player route itself is gone, and the caller — which
/// lives inside the shell's content navigator — pushes the detail route there
/// so the shell's back button still works.
Future<PlayerExit?> openFullPlayer(
  BuildContext context, {
  required MediaPlan plan,
  required String title,
  required SourceApi api,
  required String itemId,
  List<Episode> episodes = const [],
  String episodeId = '',
  Duration initialPosition = Duration.zero,
  String cover = '',
}) async {
  // Never let a feed or another player keep decoding under the new route.
  await PlaybackCoordinator.instance.pauseAll();
  if (!context.mounted) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<PlayerExit>(
    PageRouteBuilder<PlayerExit>(
      opaque: true,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => PlayerScreen(
        plan: plan,
        title: title,
        api: api,
        itemId: itemId,
        episodes: episodes,
        episodeId: episodeId,
        initialPosition: initialPosition,
        cover: cover,
      ),
    ),
  );
}

/// Registered `player` page: expected to receive a MediaPlan in context data.
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key, required this.ctx});

  final PageContext ctx;

  @override
  Widget build(BuildContext context) {
    final plan = ctx.data['plan'];
    if (plan is! MediaPlan) {
      return const StatePanel(
        icon: Icons.play_circle_outline,
        title: AppStrings.noStream,
        body: AppStrings.emptyBody,
      );
    }
    return PlayerScreen(
      plan: plan,
      title: ctx.data['title']?.toString() ?? '',
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.plan,
    this.title = '',
    this.api,
    this.itemId = '',
    this.episodes = const [],
    this.episodeId = '',
    this.autoPlayNext = false,
    this.initialPosition = Duration.zero,
    this.cover = '',
    this.localFiles = const [],
    this.windowToggle = false,
  });

  final MediaPlan plan;
  final String title;
  final SourceApi? api;
  final String itemId;
  final List<Episode> episodes;
  final String episodeId;
  final bool autoPlayNext;
  final Duration initialPosition;
  final String cover;

  /// Local playlist (files or a dropped directory). When set, episode ids are
  /// absolute paths and every switch builds its plan on the device.
  final List<String> localFiles;

  /// Shows the in-app maximize button: the sidebar player can fill the whole
  /// window without entering OS fullscreen.
  final bool windowToggle;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // The player shows the whole frame: vertical dramas must not be cropped.
  // Current episode plus N upcoming ones, opened paused (设置 → 预加载数量).
  late final PlaybackPool _pool;
  bool _playbackReady = false;

  PlaybackEngine get _engine => _pool.active;
  final FocusNode _pageFocus = FocusNode(debugLabel: 'player');
  /// Signed stream URLs (this source's HLS links carry an auth key) stop
  /// working after a few minutes. A cached plan is therefore only trusted for
  /// a short window — reusing an older one is exactly what made a scrolled-to
  /// episode fail while closing and reopening it worked.
  static const Duration _planTtl = Duration(seconds: 20);
  final Map<String, ({MediaPlan plan, DateTime at})> _planCache = {};

  MediaPlan? _cachedPlan(String key) {
    final entry = _planCache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > _planTtl) {
      _planCache.remove(key);
      return null;
    }
    return entry.plan;
  }

  void _storePlan(String key, MediaPlan plan) {
    _planCache[key] = (plan: plan, at: DateTime.now());
  }
  final Set<String> _warming = {};

  late List<Episode> _episodes;
  late String _episodeId;
  late String _quality;
  // The work currently on screen. 作品系列 replaces these in place instead of
  // pushing a second player, so the route always describes the current work.
  late String _itemId;
  late String _title;
  late String _cover;
  // Likes are per episode. The episode DTO is a snapshot taken when the list
  // was fetched, so remember writes here until the list is refreshed.
  final Map<String, ({bool liked, int likeCount})> _likeOverrides = {};
  MediaPlan? _plan;
  LocalLibrary? _library;
  PlaybackEngine? _poolListenerEngine;
  // True from the moment a new episode starts opening until its first
  // frames arrive; the video surface is covered while it is set.
  bool _switching = false;
  // One automatic reopen per open attempt: a dead signed URL is fixed by a
  // fresh plan, and looping forever would just hide the real failure.
  bool _autoRetried = false;
  // Latest episode-switch request; older completions must not win.
  int _episodeToken = 0;
  // Volume lives here, not in a single engine: a preloaded engine starts at
  // 100% and used to jump as soon as it was adopted.
  double _volume = 1.0;
  Timer? _volumeSaveTimer;
  Timer? _switchWatchdog;
  bool _isLocal = false;
  ThumbStrip? _localThumbs;
  // Preview strips built by the client from the stream itself, one attempt per
  // episode identity per session.
  final Set<String> _thumbRequests = {};
  // Bumped on every series switch so a running sprite prefetch stops.
  int _spriteToken = 0;
  // Remote sprites are HEIF; the bundled ffmpeg converts them to a local JPEG
  // keyed by their gateway URL, and the decoded size supplies the tile size.
  final Map<String, SpriteImage> _spriteFiles = {};
  /// Last attempt per sheet URL. One attempt per URL for the session meant
  /// a single timeout (a CDN hiccup) left the episode with no preview at all.
  final Map<String, int> _spriteRequestedAt = {};
  int _downloadQueued = 0;
  Timer? _downloadNoticeTimer;

  Timer? _hideTimer;
  Timer? _tick;
  Timer? _speedHideTimer;
  Timer? _noticeTimer;
  Timer? _thumbsTimer;
  String? _notice;
  Item? _item;
  List<Item> _albumItems = const [];
  bool _albumLoaded = false;
  bool _controlsVisible = true;
  bool _loading = true;
  bool _resumed = false;
  String? _error;
  // A quality switch keeps the previous plan until the new stream proves it
  // can produce a frame; a dead line must not end playback.
  MediaPlan? _revertTo;
  Duration _revertPosition = Duration.zero;
  bool _revertPlaying = false;
  List<DanmakuLine> _danmaku = const [];
  // Danmaku we sent: upstream queues them for review, so they are merged into
  // every reload until the server starts returning them.
  final Map<String, List<DanmakuLine>> _pendingDanmaku = {};
  bool _danmakuOn = true;
  bool _danmakuTimedToDuration = false;
  bool _danmakuNeedsLogin = false;
  int _lastDanmakuRetryMs = 0;
  int _danmakuWindow = -1;
  int _lastDanmakuLoadMs = 0;
  bool _advancing = false;
  bool _fullscreen = false;
  LocalWindowMode? _windowMode;
  bool _windowMaximized = false;
  bool _speedHover = false;
  double _lastVolume = 1;
  AppController? _appController;
  String _episodeLabel = '';
  int _lastWheelMs = 0;
  int _lastRemoteSaveMs = 0;
  String _lastRemoteEpisode = '';
  Set<String> _watchedIds = <String>{};
  bool _watchedLoaded = false;

  String get _seriesKey =>
      '${widget.api?.sourceId ?? 'local'}:$_itemId';
  String get _cacheKey => '$_episodeId|$_quality';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _library = AppScope.of(context).library;
    _windowMode = AppScope.of(context).windowMode;
    _appController = AppScope.controllerOf(context);
    if (!_playbackReady) {
      _playbackReady = true;
      _initPlayback();
    }
    if (!_watchedLoaded) {
      _watchedLoaded = true;
      unawaited(_loadWatched());
    }
  }

  Future<void> _loadWatched() async {
    final library = _library;
    if (library == null) return;
    final ids = <String>{};
    try {
      final positions = await library.episodePositions(_seriesKey);
      positions.forEach((id, sec) {
        if (sec > 5) ids.add(id);
      });
    } on Object {
      // Local history is optional.
    }
    final api = widget.api;
    if (api != null) {
      var index = -1;
      try {
        final payload = await api.progress(_itemId);
        if (payload['logged_in'] != false) {
          index = _accountIndex(payload);
        }
      } on Object {
        // Account progress needs login; local marks still apply.
      }
      if (index < 0) {
        try {
          final page = await api.history(limit: 50);
          for (final item in page.items) {
            if (item.id != _itemId) continue;
            final raw = item.extra['vid_index'];
            if (raw is num) index = raw.toInt();
            break;
          }
        } on Object {
          // No account history.
        }
      }
      if (index >= 0) {
        for (final episode in _episodes) {
          if (episode.index <= index) ids.add(episode.id);
        }
      }
    }
    if (!mounted) return;
    setState(() => _watchedIds = ids);
  }

  int _accountIndex(Map<String, dynamic> payload) {
    final rows = <Map<String, dynamic>>[];
    void take(Object? value) {
      if (value is! List) return;
      for (final row in value) {
        if (row is Map) rows.add(Map<String, dynamic>.from(row));
      }
    }

    final data = payload['data'];
    if (data is Map) {
      take(data['video_data']);
      take(data['data']);
    }
    take(payload['video_data']);
    for (final row in rows) {
      final id =
          '${row['book_id'] ?? row['book_id_str'] ?? row['series_id'] ?? ''}';
      if (id != _itemId) {
        continue;
      }
      final index = row['vid_index'];
      if (index is num) return index.toInt();
    }
    return -1;
  }

  @override
  void initState() {
    super.initState();
    _itemId = widget.itemId;
    _title = widget.title;
    _cover = widget.cover;
    _episodes = widget.episodes;
    if (widget.localFiles.isNotEmpty) {
      _episodes = [
        for (var i = 0; i < widget.localFiles.length; i++)
          Episode(
            id: widget.localFiles[i],
            index: i + 1,
            title: LocalMedia.titleFor(widget.localFiles[i]),
          ),
      ];
    }
    _episodeId = widget.episodeId.isNotEmpty
        ? widget.episodeId
        : (widget.localFiles.isNotEmpty
            ? widget.localFiles.first
            : widget.plan.episodeId);
    _episodeLabel = _labelFor(_episodeId);
    // Metadata does not depend on playback: start every request now so the
    // page is populated by the time the first frame is on screen.
    if (widget.api != null) {
      unawaited(_loadEpisodes());
      unawaited(_loadDanmaku());
      if (_itemId.isNotEmpty) {
        unawaited(_loadInfo());
        unawaited(_loadAlbum());
      }
    }
  }

  /// The pool needs the settings (inherited), and playback must not start
  /// before the pool exists: both happen on the first dependency pass.
  void _initPlayback() {
    _volume =
        AppScope.controllerOf(context).settings.volume.clamp(0.0, 1.0);

    // Pool size follows the setting; only the immediate next episode is
    // actually opened in a spare engine (see _prefetchNext), so a larger pool
    // costs slots, not decoding threads.
    final preload = AppScope.controllerOf(context)
        .settings
        .preloadAhead
        .clamp(1, 4);
    _pool = PlaybackPool(size: preload + 1, fit: BoxFit.contain);
    String? localPath;
    if (widget.localFiles.isNotEmpty) {
      _isLocal = true;
      localPath = _episodeId;
      _plan = widget.plan;
    } else {
      localPath = AppScope.of(context)
          .downloads
          .localPathFor(_seriesKey, _episodeId);
      if (localPath != null) {
        _isLocal = true;
        _plan = LocalMedia.buildPlan(localPath);
      } else {
        _plan = widget.plan;
      }
    }
    if (localPath != null) {
      _loadLocalThumbs(localPath);
    } else if (_plan != null) {
      _deferThumbs(_plan!);
    }
    _quality = _plan?.bestStream?.quality ?? '';
    _storePlan(_cacheKey, _plan!);
    _pool.onActiveChanged = (engine) {
      _poolListenerEngine?.snapshot.removeListener(_onSnapshot);
      _poolListenerEngine = engine;
      engine.snapshot.addListener(_onSnapshot);
    };
    _poolListenerEngine = _engine;
    _engine.snapshot.addListener(_onSnapshot);
    _start();
    _prefetchSprites();
    _scheduleHide();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveProgress();
      _retryDanmakuIfNeeded();
    });
  }

  void _onSnapshot() {
    final snapshot = _engine.snapshot.value;
    // The engine reports a dead stream here, not through the open() future.
    // Without this the player sat on a black frame with no message at all.
    final engineError = snapshot.error;
    if (engineError != null && _error == null) {
      AppLog.write('player error: $engineError');
      if (!_autoRetried && widget.api != null && !_isLocal) {
        _autoRetried = true;
        unawaited(_retryCurrent());
        return;
      }
      setState(() {
        _error = engineError;
        _switching = false;
        _loading = false;
      });
      return;
    }
    if (_switching && snapshot.ready && snapshot.position > Duration.zero) {
      _switchWatchdog?.cancel();
      _revertTo = null;
      setState(() => _switching = false);
      // Neighbour prefetch is deliberately deferred while a switch is in
      // flight; run it once the new episode actually has frames.
      _prefetchNext(3);
    }
    if (!_danmakuTimedToDuration && snapshot.duration.inSeconds > 30) {
      // The first danmaku fetch happens before the container reports its
      // duration; re-time the lines once it is known.
      _danmakuTimedToDuration = true;
      _loadDanmaku();
    }
    if (!_danmakuNeedsLogin && snapshot.duration > Duration.zero) {
      // Danmaku is served in 30s windows: follow the playhead so lines from
      // the current minute actually arrive.
      final window = snapshot.position.inSeconds ~/ 30;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (window != _danmakuWindow && now - _lastDanmakuLoadMs > 2000) {
        _lastDanmakuLoadMs = now;
        _loadDanmaku();
      }
    }
    if (!snapshot.completed || _advancing) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0 || index + 1 >= _episodes.length) return;
    // Watched to the end: the next visit starts this episode over.
    _clearEpisodePosition(_episodes[index].id);
    if (!AppScope.controllerOf(context).settings.autoPlayNext) {
      _showNotice('本集已播完');
      return;
    }
    _advancing = true;
    _stepEpisode(1).whenComplete(() => _advancing = false);
  }

  void _clearEpisodePosition(String episodeId) {
    final library = _library;
    if (library == null) return;
    unawaited(
      library.recordEpisodePosition(
        _seriesKey,
        episodeId,
        positionSec: 0,
        durationSec: 0,
      ),
    );
  }

  /// Speed is global: every open (first episode, next episode, quality switch)
  /// re-applies the stored preference because media_kit resets it per media.
  Future<void> _applySavedRate() async {
    try {
      await _engine.setVolume(_volume);
    } on Object {
      // Volume is best-effort; playback still works.
    }
    final library = _library;
    if (library == null) return;
    try {
      final rate = await library.playbackRate();
      if ((rate - 1.0).abs() > 0.001) await _engine.setRate(rate);
    } on Object {
      // 1x is the safe default when the store cannot be read.
    }
  }

  void _rememberRate(double rate) {
    final library = _library;
    if (library == null) return;
    unawaited(library.setPlaybackRate(rate));
  }

  /// Frosted notice at the top of the video: the bottom is reserved for the
  /// progress bar and the controls.
  void _showNotice(String text) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// A quality picked earlier applies to the next work too, not only to the
  /// episode it was chosen on. It lives in the settings, so this also covers
  /// a plan that arrived from a place that did not ask for it.
  Future<MediaPlan> _withSavedQuality(MediaPlan plan) async {
    final saved = AppScope.controllerOf(context).settings.defaultQuality;
    if (saved.isEmpty || saved == 'auto') return plan;
    if (plan.bestStream?.quality == saved) return plan;
    if (!plan.streams.any((stream) => stream.quality == saved)) return plan;
    try {
      return await _planFor(_episodeId, quality: saved);
    } on Object {
      return plan;
    }
  }

  Future<void> _start() async {
    try {
      _autoRetried = false;
      _switching = true;
      _armWatchdog();
      final plan = await _withSavedQuality(_plan ?? widget.plan);
      if (!mounted) return;
      if (!identical(plan, _plan)) {
        _plan = plan;
        _quality = plan.bestStream?.quality ?? _quality;
        _storePlan('$_episodeId|$_quality', plan);
      }
      await _pool.openActive(_episodeId, plan);
      await _applySavedRate();
      await _engine.play();
      if (!mounted) return;
      final engineError = _engine.snapshot.value.error;
      if (engineError != null && !_autoRetried && widget.api != null && !_isLocal) {
        // The plan handed in may already be a minute old; one fresh request
        // usually plays the same episode.
        _autoRetried = true;
        unawaited(_retryCurrent());
        return;
      }
      setState(() {
        _loading = false;
        _error = engineError;
      });
      if (engineError != null) return;
      // The plan is only known now; without this the prefetch that ran from
      // initState or just after the episode list arrived could have bailed out
      // on a null plan and the episode would have no thumbnails at all.
      _prefetchSprites();
      if (widget.initialPosition > Duration.zero) {
        // Hand-off from the home feed: continue at the exact position the
        // feed was playing instead of restarting the episode.
        _resumed = true;
        await _seekWhenReady(widget.initialPosition, episodeId: _episodeId);
      }
      await _restoreProgress();
      _prefetchNext(3);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _tick?.cancel();
    _speedHideTimer?.cancel();
    _noticeTimer?.cancel();
    _switchWatchdog?.cancel();
    _thumbsTimer?.cancel();
    _volumeSaveTimer?.cancel();
    _poolListenerEngine?.snapshot.removeListener(_onSnapshot);
    _engine.snapshot.removeListener(_onSnapshot);
    _saveProgress();
    if (_fullscreen) {
      WindowControls.setFullscreen(false);
      _appController?.setImmersive(false);
    }
    if (_windowMaximized) {
      // The shell owns the sidebar; asking it to restore after this frame
      // keeps the reset out of the unmount/build phase.
      final mode = _windowMode;
      WidgetsBinding.instance.addPostFrameCallback((_) => mode?.reset());
    }
    _pageFocus.dispose();
    // Stop decoding before the (unawaited) async teardown completes. The
    // whole pool has to go: the spare engines are real libmpv instances, and
    // disposing only the active one leaked them on every page close.
    unawaited(_pool.pauseAll());
    unawaited(_pool.dispose());
    super.dispose();
  }

  /// media_kit drops a seek issued before the container reports its duration,
  /// which made resume look like a no-op. Wait for it, then clamp.
  Future<void> _seekWhenReady(Duration target, {String? episodeId}) async {
    if (target <= Duration.zero) return;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (episodeId != null && episodeId != _episodeId) return;
      if (_engine.snapshot.value.duration > Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted) return;
    // The episode changed while waiting: this position belongs to the old one.
    if (episodeId != null && episodeId != _episodeId) return;
    final duration = _engine.snapshot.value.duration;
    var position = target;
    if (duration > Duration.zero &&
        position > duration - const Duration(seconds: 3)) {
      position = duration - const Duration(seconds: 3);
      if (position < Duration.zero) position = Duration.zero;
    }
    await _engine.seek(position);
  }

  // -------------------------------------------------------------- resume

  Future<void> _restoreProgress() async {
    final library = _library;
    if (_resumed || library == null) return;
    _resumed = true;
    final episodeId = _episodeId;
    try {
      // The per-episode map is the most precise: it exists even when the user
      // jumped between episodes inside the player.
      var seconds = await library.episodePosition(_seriesKey, episodeId);
      if (seconds < 5) {
        final history = await library.history();
        for (final row in history) {
          if (row.seriesKey != _seriesKey) continue;
          if (row.episodeId.isNotEmpty && row.episodeId != episodeId) break;
          seconds = row.positionSec;
          break;
        }
      }
      if (!mounted || seconds < 5) return;
      final target = Duration(seconds: seconds);
      await _seekWhenReady(target, episodeId: episodeId);
      if (!mounted) return;
      _showNotice('已续播 ${_format(target)}');
    } on Object {
      // History is best-effort.
    }
  }

  /// Resumes the position remembered for one episode (used when switching back
  /// to an earlier episode inside the player).
  Future<void> _resumeEpisode(String episodeId) async {
    final library = _library;
    if (library == null || episodeId.isEmpty) return;
    try {
      final seconds = await library.episodePosition(_seriesKey, episodeId);
      if (seconds < 5 || !mounted) return;
      final target = Duration(seconds: seconds);
      await _seekWhenReady(target);
      if (!mounted) return;
      _showNotice('已续播 ${_format(target)}');
    } on Object {
      // Best-effort.
    }
  }

  Future<void> _saveProgress() async {
    final api = widget.api;
    final library = _library;
    if (library == null || _itemId.isEmpty) return;
    final snapshot = _engine.snapshot.value;
    if (snapshot.duration <= Duration.zero) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    final completed = snapshot.completed;
    final position = completed ? snapshot.duration : snapshot.position;
    // A freshly opened episode starts at zero; without this guard the first
    // tick would replace a real position from an earlier session with 0s.
    if (!completed && position.inSeconds < 5) return;
    try {
      await library.recordProgress(
            LibraryRecord(
              seriesKey: _seriesKey,
              title: _title,
              cover: _cover.isNotEmpty
                  ? _cover
                  : (_item?.cover ?? ''),
              sourceId: api?.sourceId ?? 'local',
              itemId: _itemId,
              episodeId: _episodeId,
              episodeIndex: index >= 0 ? _episodes[index].index : 0,
              positionSec: position.inSeconds,
              durationSec: snapshot.duration.inSeconds,
              updatedAt: DateTime.now().toIso8601String(),
              episodeCount: _episodes.length,
              finished: completed,
            ),
          );
      await library.recordEpisodePosition(
        _seriesKey,
        _episodeId,
        positionSec: position.inSeconds,
        durationSec: snapshot.duration.inSeconds,
      );
      if (position.inSeconds > 5 && !_watchedIds.contains(_episodeId)) {
        setState(() => _watchedIds = {..._watchedIds, _episodeId});
      }
      if (api != null) _pushRemote(api, index, position);
    } on Object {
      // Never let persistence break playback.
    }
  }

  void _pushRemote(SourceApi api, int index, Duration position) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_episodeId == _lastRemoteEpisode && now - _lastRemoteSaveMs <= 30000) {
      return;
    }
    _lastRemoteEpisode = _episodeId;
    _lastRemoteSaveMs = now;
    final duration = _engine.snapshot.value.duration;
    unawaited(
      api
          .saveProgress(
            itemId: _itemId,
            episodeId: _episodeId,
            index: index >= 0 ? _episodes[index].index : 0,
            positionSec: position.inSeconds,
            durationSec: duration.inSeconds,
          )
          .catchError((Object _) {}),
    );
  }

  // -------------------------------------------------------------- episodes

  Future<void> _loadEpisodes() async {
    final api = widget.api;
    if (api == null || _episodes.isNotEmpty || _itemId.isEmpty) return;
    try {
      final page = await api.episodes(_itemId);
      if (!mounted) return;
      setState(() {
        _episodes = page.episodes;
        _episodeLabel = _labelFor(_episodeId);
      });
      _prefetchSprites();
    } on Object {
      // A source without episodes still plays its single stream.
    }
  }

  Future<void> _loadInfo() async {
    final api = widget.api;
    if (api == null || _itemId.isEmpty) return;
    try {
      final item = await api.detail(_itemId);
      if (!mounted) return;
      setState(() => _item = item);
    } on Object {
      // The hover card is optional.
    }
  }

  /// 作品系列 runs on its own: the season search takes seconds upstream, and
  /// waiting for /detail first would only add to that.
  Future<void> _loadAlbum() async {
    final api = widget.api;
    if (api == null || _itemId.isEmpty || _albumLoaded) return;
    _albumLoaded = true;
    try {
      final page = await api.album(_itemId);
      if (!mounted) return;
      setState(() => _albumItems = page.items);
    } on Object {
      // No series data: the entry stays hidden.
    }
  }

  /// Leaves the player and lets the caller open the detail page of the work
  /// that is actually on screen. Pushing the detail route here would stack it
  /// above the player: no shell back button, and the player keeps playing.
  Future<void> _openDetail() async {
    if (widget.api == null || _itemId.isEmpty) return;
    await _saveProgress();
    await _engine.pause();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(
      PlayerExit(
        wantsDetail: true,
        itemId: _itemId,
        title: _title,
        cover: _cover,
      ),
    );
  }

  /// Counts and unlike state belong to the episode, not the series.
  ItemStats? get _episodeStats {
    for (final episode in _episodes) {
      if (episode.id != _episodeId) continue;
      final extra = episode.extra;
      int read(String key) => extra[key] is num ? (extra[key] as num).toInt() : 0;
      final override = _likeOverrides[episode.id];
      return ItemStats(
        likeCount: override?.likeCount ?? read('like_count'),
        commentCount: read('comment_count'),
        followCount: _item?.extra['follow_count'] is num
            ? (_item!.extra['follow_count'] as num).toInt()
            : 0,
        liked: override?.liked ?? extra['liked'] == true,
      );
    }
    return null;
  }

  String _labelFor(String id) {
    for (final episode in _episodes) {
      if (episode.id == id) {
        return episode.title.isEmpty ? '第${episode.index}集' : episode.title;
      }
    }
    return '';
  }

  /// Bottom-left counter: 当前x/总数, e.g. 当前3/1000.
  String get _episodeCounter {
    if (_episodes.isEmpty) return _episodeLabel;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0) return _episodeLabel;
    final current =
        _episodes[index].index > 0 ? _episodes[index].index : index + 1;
    final total = (_item?.episodeCount ?? 0) > 0
        ? _item!.episodeCount
        : _episodes.length;
    return '当前$current/$total';
  }

  /// 作品系列: a prefetched list of the collection's works. Picking one
  /// replaces this player's work in place — never a second player route.
  Future<void> _openAlbum() async {
    final api = widget.api;
    if (api == null) return;
    final reserved = await _fetchReservedIds(api);
    if (!mounted) return;
    await showAlbumSheet(
      context,
      items: _albumItems,
      reservedIds: reserved,
      onOpen: _switchWork,
      onReserve: _reserve,
    );
  }

  /// The album has no per-item reservation flag, so read the account's
  /// reservation lists once and match by series id.
  Future<Set<String>> _fetchReservedIds(SourceApi api) async {
    final ids = <String>{};
    try {
      for (final online in const [false, true]) {
        final page = await api.reservations(limit: 50, online: online);
        for (final item in page.items) {
          if (item.id.isNotEmpty) ids.add(item.id);
        }
      }
    } on Object {
      // Logged out or offline: nothing is marked 已预约.
    }
    return ids;
  }

  Future<bool> _reserve(Item item) async {
    final api = widget.api;
    if (api == null) return false;
    try {
      await api.setReservation(item.id, true);
    } on Object catch (error) {
      if (error is! SpException || error.code != SpErrorCode.unauthorized) {
        rethrow;
      }
      if (!mounted || !await showLoginSheet(context, api: api)) return false;
      if (!mounted) return false;
      await api.setReservation(item.id, true);
    }
    if (mounted) _showNotice('已预约《${item.title}》');
    return true;
  }

  /// Plays another work from 作品系列 without leaving this route.
  Future<void> _switchWork(Item item) async {
    final api = widget.api;
    if (api == null || item.id.isEmpty || item.id == _itemId) return;
    if (item.extra['is_online'] == false) {
      _showNotice('《${item.title}》还没有上线');
      return;
    }
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.episodes(item.id);
      if (!mounted) return;
      if (page.episodes.isEmpty) {
        setState(() => _loading = false);
        _showNotice('《${item.title}》还没有可播放的剧集');
        return;
      }
      final first = page.episodes.first;
      final localPath = AppScope.of(context)
          .downloads
          .localPathFor('${api.sourceId}:${item.id}', first.id);
      _isLocal = localPath != null;
      if (localPath != null) {
        _loadLocalThumbs(localPath);
        AppScope.of(context).localPlaylist.setCurrent(localPath);
      } else {
        _localThumbs = null;
      }
      // The work that opens next uses the quality the user settled on, not
      // the highest one the new source happens to offer first.
      final savedQuality = localPath != null
          ? ''
          : AppScope.controllerOf(context).settings.defaultQuality;
      final plan = localPath != null
          ? LocalMedia.buildPlan(localPath)
          : await api.play(
              PlayRequest(
                itemId: item.id,
                episodeId: first.id,
                quality:
                    savedQuality.isEmpty ? 'auto' : savedQuality,
              ),
            );
      if (!mounted) return;
      await _pool.pauseActive();
      _pool.forgetPreloads();
      _revertTo = null;
      _switching = true;
      _armWatchdog();
      await _pool.openActive(first.id, plan);
      await _applySavedRate();
      await _engine.play();
      if (!mounted) return;
      setState(() {
        _itemId = item.id;
        _title = item.title;
        _cover = item.cover;
        _item = item;
        _episodes = page.episodes;
        _episodeId = first.id;
        _episodeLabel = _labelFor(first.id);
        _plan = plan;
        _quality = plan.bestStream?.quality ?? '';
        _planCache.clear();
        _storePlan('$_episodeId|$_quality', plan);
        _albumItems = const [];
        _albumLoaded = false;
        _watchedIds = <String>{};
        _watchedLoaded = true;
        _danmaku = const [];
        _danmakuWindow = -1;
        _danmakuTimedToDuration = false;
        _likeOverrides.clear();
        _resumed = false;
        _loading = false;
      });
      if (localPath == null) _deferThumbs(plan);
      _prefetchSprites();
      unawaited(_loadWatched());
      unawaited(_loadInfo());
      unawaited(_loadAlbum());
      _loadDanmaku();
      _prefetchNext(3);
      await _restoreProgress();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeGatewayError(error);
      });
    }
  }

  /// Some source files never produce a frame. Fail with an offer to retry
  /// instead of buffering forever.
  void _armWatchdog() {
    _switchWatchdog?.cancel();
    // Twenty seconds: a cold range-decrypt (moov + first GOP) can be slow on a
    // remote source, and a false "timeout" is worse than waiting a bit more.
    _switchWatchdog = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      final snapshot = _engine.snapshot.value;
      if (snapshot.position > Duration.zero) return;
      if (snapshot.error != null) return;
      debugPrint(
        'player watchdog: pos=${snapshot.position.inMilliseconds}ms '
        'dur=${snapshot.duration.inMilliseconds}ms '
        'buffering=${snapshot.buffering} err=${snapshot.error} '
        'source=${widget.api?.sourceId ?? '-'} '
        'local=$_isLocal',
      );
      if (_revertTo != null) {
        unawaited(_restoreAfterFailedSwitch());
        return;
      }
      // Signed links die quietly; one fresh plan usually plays the same
      // episode, which is why reopening the player always worked.
      if (!_autoRetried && widget.api != null && !_isLocal) {
        _autoRetried = true;
        unawaited(_retryCurrent());
        return;
      }
      setState(() {
        _switching = false;
        _loading = false;
        _error = '视频加载超时，可能是源文件无法播放';
      });
    });
  }

  Future<void> _retryCurrent() async {
    final api = widget.api;
    if (api == null || _episodeId.isEmpty) return;
    // A retry replaces the stream, not the place in it: a line that died at
    // 12:30 must not come back at 0:00.
    final resumeAt = _engine.snapshot.value.position;
    setState(() {
      _error = null;
      _loading = true;
    });
    _planCache.remove(_cacheKey);
    try {
      var localPath = AppScope.of(context)
          .downloads
          .localPathFor(_seriesKey, _episodeId);
      if (localPath == null &&
          widget.localFiles.isNotEmpty &&
          File(_episodeId).existsSync()) {
        localPath = _episodeId;
      }
      _isLocal = localPath != null;
      if (localPath != null) {
        _loadLocalThumbs(localPath);
        AppScope.of(context).localPlaylist.setCurrent(localPath);
      } else {
        _localThumbs = null;
      }
      final plan = localPath != null
          ? LocalMedia.buildPlan(localPath)
          : await _planFor(_episodeId, quality: _quality);
      if (!mounted) return;
      _revertTo = null;
      _switching = true;
      _armWatchdog();
      await _pool.openActive(_episodeId, plan);
      await _applySavedRate();
      if (resumeAt > Duration.zero) {
        try {
          await _seekWhenReady(resumeAt, episodeId: _episodeId);
        } on Object {
          // Play from the start rather than fail the retry.
        }
      }
      await _engine.play();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _quality = plan.bestStream?.quality ?? _quality;
        _loading = false;
      });
      if (localPath == null) _deferThumbs(plan);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  /// A source only has to return a playable MP4. When it ships no sprite, the
  /// client samples the stream with the bundled ffmpeg and builds its own;
  /// encrypted streams are read through the loopback decrypt proxy.
  /// Sampling a strip costs ffmpeg a probe plus one seek per tile. Doing it
  /// at the moment of a switch competes with the new stream for CPU and
  /// sockets, which reads as a stutter; wait for playback to settle.
  void _deferThumbs(MediaPlan plan) {
    _thumbsTimer?.cancel();
    _thumbsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !identical(_plan, plan)) return;
      _loadGeneratedThumbs(plan);
    });
  }

  void _loadGeneratedThumbs(MediaPlan plan) {
    // A declared or plain sprite address is already the source's own artwork.
    if (plan.thumbs != null || plan.spriteUrl != null) return;
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) return;
    final key = VideoThumbs.keyFor(stream.url);
    final known = VideoThumbs.cached(key);
    if (known != null) {
      _localThumbs = known;
      return;
    }
    if (!_thumbRequests.add(key)) return;
    final decryption = stream.decryption ?? plan.decryption;
    final encrypted = decryption.required &&
        decryption.location == 'client' &&
        decryption.keyHex.isNotEmpty;
    unawaited(() async {
      var source = stream.url;
      if (encrypted) {
        try {
          source = await DecryptProxy.instance.register(
            stream.url,
            decryption.keyHex,
          );
        } on Object {
          return;
        }
      }
      final strip = await VideoThumbs.load(source, cacheKey: key);
      if (!mounted || strip == null || _plan != plan) return;
      setState(() => _localThumbs = strip);
    }());
  }

  /// Downloaded/open local files have no source sprite; ffmpeg builds one
  /// and the seek bar picks it up when ready.
  void _loadLocalThumbs(String path) {
    final cached = LocalThumbs.cached(path);
    _localThumbs = cached;
    if (cached != null) return;
    unawaited(LocalThumbs.load(path).then((strip) {
      if (!mounted || strip == null || !_isLocal) return;
      setState(() => _localThumbs = strip);
    }));
  }

  Future<MediaPlan> _planFor(
    String episodeId, {
    String? quality,
    bool cache = true,
  }) async {
    final q = quality ?? _quality;
    final key = '$episodeId|$q';
    final cached = _cachedPlan(key);
    if (cached != null) return cached;
    final api = widget.api;
    if (api == null) {
      if (File(episodeId).existsSync()) {
        final plan = LocalMedia.buildPlan(episodeId);
        if (cache) _storePlan(key, plan);
        return plan;
      }
      throw const SpException(SpErrorCode.unsupported, '没有数据源');
    }
    final plan = await api.play(
      PlayRequest(
        itemId: _itemId,
        episodeId: episodeId,
        quality: q.isEmpty ? 'auto' : q,
      ),
    );
    // A preview-only lookup must not pin a short-lived plan (stream URLs and
    // keys expire) for an episode that is not playing yet.
    if (cache) _storePlan(key, plan);
    return plan;
  }

  /// Source sprites are tiny next to a video, so warm the ones around the
  /// episode being watched as soon as the list is known: switching episodes
  /// then shows a preview immediately instead of waiting for a request.
  ///
  /// Each sheet costs one `/play` to learn its address, so the window is
  /// exactly the two episodes that can be on screen now: the one playing and
  /// the one auto-play moves to. Opening a series used to fire forty of these
  /// at once, which was the burst that made the page stutter; the window
  /// slides on every episode switch instead.
  /// Only the source-sprite mode is prefetched; with no sheet the client
  /// generates from the video, and doing that for every episode would mean
  /// seeking through all of them.
  void _prefetchSprites() {
    // Always bump the token: a series switch must stop the previous run even
    // when the new series has no sprites.
    final token = ++_spriteToken;
    if (widget.api == null) return;
    // The playing episode's sheet starts now, not after the episode list
    // arrives: dragging the bar before that used to show black thumbnails
    // because nothing had been requested yet.
    final playing = _plan?.spriteUrl;
    if (playing != null && playing.startsWith('http')) _requestSprite(playing);
    if (_episodes.isEmpty) return;
    if (_plan?.spriteUrl == null) return;
    final ids = [for (final episode in _episodes) episode.id];
    final current = ids.indexOf(_episodeId);
    if (current < 0) return;
    final end = (current + 2).clamp(0, ids.length);
    final queue = ids.sublist(current, end);
    var cursor = 0;
    var failures = 0;
    Future<void> worker() async {
      while (cursor < queue.length) {
        if (!mounted || token != _spriteToken) return;
        final id = queue[cursor++];
        try {
          final plan = await _planFor(id, cache: false);
          failures = 0;
          final url = plan.spriteUrl;
          if (url != null &&
              url.startsWith('http') &&
              !_spriteFiles.containsKey(url)) {
            final image = await RemoteSprite.ensure(url);
            // No setState: the map is read on the next episode switch, and a
            // rebuild per sheet while a video plays would stutter.
            if (image != null && mounted && token == _spriteToken) {
              _spriteFiles[url] = image;
            }
          }
        } on Object {
          // An upstream that starts refusing requests is not warmed further:
          // the rest of the list stays on-demand.
          if (++failures >= 3) return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    for (var i = 0; i < 2; i++) {
      unawaited(worker());
    }
  }

  /// Resolves the next episodes in the background; the gateway warms their
  /// media index in the same call. Only the immediate next one is opened in a
  /// spare engine, and only after the current episode settled: preloading two
  /// more streams at the instant of a switch is what made the switch stutter.
  void _prefetchNext(int count) {
    if (_episodes.isEmpty) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0) return;
    for (var i = index + 1; i <= index + count && i < _episodes.length; i++) {
      final id = _episodes[i].id;
      final near = i == index + 1;
      final cached = _cachedPlan('$id|$_quality');
      if (cached != null) {
        if (near && widget.api != null && !_switching) {
          unawaited(_preloadSoon(id, cached));
        }
        continue;
      }
      if (!_warming.add(id)) continue;
      _planFor(id).then((plan) {
        // The rest are warmed at the gateway by the plan call itself.
        if (near && widget.api != null && !_switching) {
          unawaited(_preloadSoon(id, plan));
        }
      }).catchError((Object _) {
        _warming.remove(id);
      });
    }
  }

  /// Opens the next episode in a spare engine, but only once the one on
  /// screen has had a moment to start.
  Future<void> _preloadSoon(String id, MediaPlan plan) async {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted || _switching) return;
    await _pool.preload(id, plan);
  }

  Future<void> _playEpisode(Episode episode) async {
    if (episode.id == _episodeId) return;
    // Rapid scrolling can start a second switch while the first is still
    // fetching; only the latest one may touch the engine or the page state.
    final token = ++_episodeToken;
    _autoRetried = false;
    await _saveProgress();
    if (!mounted || token != _episodeToken) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // A local playlist's episode id is its file path; downloads also
      // resolve through the manager. Either way the episode is local.
      var localPath = AppScope.of(context)
          .downloads
          .localPathFor(_seriesKey, episode.id);
      if (localPath == null &&
          widget.localFiles.isNotEmpty &&
          File(episode.id).existsSync()) {
        localPath = episode.id;
      }
      final plan = localPath != null
          ? LocalMedia.buildPlan(localPath)
          : await _planFor(episode.id);
      if (!mounted || token != _episodeToken) return;
      _isLocal = localPath != null;
      if (localPath != null) {
        _loadLocalThumbs(localPath);
        AppScope.of(context).localPlaylist.setCurrent(localPath);
      } else {
        _localThumbs = null;
      }
      _revertTo = null;
      _switching = true;
      _armWatchdog();
      final adopted = await _pool.adopt(episode.id);
      if (!mounted || token != _episodeToken) return;
      if (!adopted) {
        await _pool.openActive(episode.id, plan);
        await _engine.play();
        if (!mounted || token != _episodeToken) return;
      }
      if (_engine.snapshot.value.error != null && !_autoRetried) {
        _autoRetried = true;
        unawaited(_retryCurrent());
        return;
      }
      // A preloaded engine was opened with default speed; apply the user's
      // choice to whichever engine is now playing.
      await _applySavedRate();
      if (!mounted || token != _episodeToken) return;
      setState(() {
        _episodeId = episode.id;
        _episodeLabel = _labelFor(episode.id);
        _plan = plan;
        _danmakuTimedToDuration = false;
        _danmaku = const [];
        _loading = false;
      });
      if (localPath == null) _deferThumbs(plan);
      _loadDanmaku();
      _prefetchNext(3);
      // Continue this episode where it stopped last time, not the series'
      // latest position.
      await _resumeEpisode(episode.id);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  Future<void> _stepEpisode(int delta) async {
    if (_episodes.isEmpty) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0) return;
    final next = index + delta;
    if (next < 0 || next >= _episodes.length) return;
    await _playEpisode(_episodes[next]);
  }

  // -------------------------------------------------------------- danmaku

  Future<void> _loadDanmaku() async {
    final api = widget.api;
    if (api == null) return;
    final episodeId = _episodeId;
    try {
      final snapshot = _engine.snapshot.value;
      final duration = snapshot.duration.inSeconds;
      final offset = snapshot.position.inSeconds;
      final page = await api.danmaku(
        itemId: _itemId,
        episodeId: episodeId,
        durationSec: duration > 0 ? duration : 180,
        offsetSec: offset,
      );
      // A slow window for the previous episode must not paint over the one
      // that is playing now.
      if (!mounted || episodeId != _episodeId) return;
      final wasLoggedOut = _danmakuNeedsLogin;
      final pending = _pendingDanmaku[episodeId] ?? const <DanmakuLine>[];
      final ids = page.items.map((line) => line.id).toSet();
      setState(() {
        _danmaku = [
          ...page.items,
          ...pending.where((line) => !ids.contains(line.id)),
        ];
        _danmakuNeedsLogin = false;
        _danmakuWindow = offset ~/ 30;
      });
      if (wasLoggedOut) {
        // The user logged in mid-playback: send this episode's position right
        // away instead of waiting for the 30s remote window.
        _lastRemoteSaveMs = 0;
        _saveProgress();
      }
    } on Object catch (error) {
      if (!mounted) return;
      // Unlogged accounts get an auth error: retry on a timer so danmaku
      // appear as soon as the user logs in, without reopening the player.
      setState(() {
        _danmaku = List<DanmakuLine>.from(
          _pendingDanmaku[_episodeId] ?? const <DanmakuLine>[],
        );
        _danmakuNeedsLogin =
            error is SpException && error.code == SpErrorCode.unauthorized;
      });
    }
  }

  void _addLocalDanmaku(DanmakuLine line) {
    final list = _pendingDanmaku.putIfAbsent(_episodeId, () => <DanmakuLine>[]);
    list.insert(0, line);
    if (!mounted) return;
    setState(() => _danmaku = [line, ..._danmaku]);
  }

  void _retryDanmakuIfNeeded() {
    if (!_danmakuNeedsLogin || !_danmakuOn) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDanmakuRetryMs < 30000) return;
    _lastDanmakuRetryMs = now;
    _loadDanmaku();
  }

  Future<void> _openDownload() async {
    final api = widget.api;
    if (api == null || _episodes.isEmpty) return;
    unawaited(_saveProgress());
    final item = _item ??
        Item(id: _itemId, title: _title, cover: _cover);
    final queued = await showDownloadSheet(
      context,
      api: api,
      item: item,
      episodes: _episodes,
      initialEpisodeId: _episodeId,
      cover: _cover,
    );
    if (queued > 0 && mounted) _showDownloadNotice(queued);
  }

  void _showDownloadNotice(int count) {
    _downloadNoticeTimer?.cancel();
    setState(() => _downloadQueued = count);
    _downloadNoticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _downloadQueued = 0);
    });
  }

  /// Closes the player and asks the shell for the downloads page.
  void _openDownloadsPage() {
    final navigator = AppScope.of(context).navigator;
    _downloadNoticeTimer?.cancel();
    Navigator.of(context, rootNavigator: true).pop();
    navigator.request(PageTypes.libraryDownloads);
  }

  Future<void> _openDanmaku() async {
    final api = widget.api;
    if (api == null) return;
    await showDanmakuSheet(
      context,
      api: api,
      itemId: _itemId,
      episodeId: _episodeId,
      positionSec: _engine.snapshot.value.position.inSeconds,
      durationSec: _engine.snapshot.value.duration.inSeconds,
      lines: _danmaku,
      onChanged: _loadDanmaku,
      onSent: _addLocalDanmaku,
    );
    if (!mounted) return;
    _loadDanmaku();
  }

  // -------------------------------------------------------------- quality

  Future<void> _switchQuality(Stream stream) async {
    if (stream.quality == _quality) return;
    final api = widget.api;
    if (api == null) return;
    final previous = _plan;
    setState(() => _loading = true);
    try {
      final plan = await _planFor(_episodeId, quality: stream.quality);
      if (!mounted) return;
      if (plan.streams.isEmpty) {
        setState(() => _loading = false);
        _showNotice('该清晰度暂不可用');
        return;
      }
      // Open the exact stream the user picked: the gateway already honours
      // `quality`, but ordering it first removes any ambiguity.
      final chosen = plan.streams.firstWhere(
        (item) => item.quality == stream.quality,
        orElse: () => plan.streams.first,
      );
      final direct = MediaPlan(
        itemId: plan.itemId,
        episodeId: plan.episodeId,
        streams: [chosen, ...plan.streams.where((item) => item != chosen)],
        decryption: plan.decryption,
        expiresAt: plan.expiresAt,
        nextEpisodeId: plan.nextEpisodeId,
        downgraded: plan.downgraded,
        extra: plan.extra,
      );
      // Preparing the plan takes seconds and the picture keeps playing: read
      // the live state again so the new stream resumes where it actually is,
      // not where it was when the quality sheet was opened.
      final resumeAt = _engine.snapshot.value.position;
      final wasPlaying = _engine.snapshot.value.playing;
      // Lines die without notice: hold the previous plan until the new stream
      // shows a frame, so a dead line cannot end playback.
      _revertTo = previous;
      _revertPosition = resumeAt;
      _revertPlaying = wasPlaying;
      _switching = true;
      _armWatchdog();
      await _pool.openActive(_episodeId, direct);
      if (_engine.snapshot.value.error != null) {
        await _restoreAfterFailedSwitch();
        return;
      }
      await _applySavedRate();
      if (resumeAt > Duration.zero) {
        try {
          // A seek issued before the new stream has a duration is dropped by
          // the engine, which is why the picture restarted from 0:00.
          await _seekWhenReady(resumeAt, episodeId: _episodeId);
        } on Object {
          // The open failed under a live seek; the watchdog decides.
        }
      }
      if (wasPlaying) await _engine.play();
      if (!mounted) return;
      _revertTo = null;
      setState(() {
        _quality = chosen.quality;
        _plan = direct;
        _loading = false;
        // A previous failure must not leave the error panel on screen (and
        // keep hiding later engine errors behind it).
        _error = null;
      });
      // The picker is a global preference: the feed and the next player
      // should start on the same quality.
      final controller = AppScope.controllerOf(context);
      unawaited(controller.updateSettings(
        controller.settings.copyWith(defaultQuality: chosen.quality),
      ));
    } on Object catch (error) {
      if (!mounted) return;
      // The previous line may still be alive: fall back to it instead of
      // covering a playing picture with a fatal error panel.
      if (_revertTo != null) {
        await _restoreAfterFailedSwitch();
        _showNotice('该清晰度暂不可用，已切回原清晰度');
        return;
      }
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  /// The chosen line never produced a frame: resume the previous quality at
  /// the same position instead of leaving the player dead.
  Future<void> _restoreAfterFailedSwitch() async {
    final previous = _revertTo;
    final position = _revertPosition;
    final playing = _revertPlaying;
    _revertTo = null;
    _switchWatchdog?.cancel();
    if (!mounted) return;
    if (previous == null) {
      setState(() {
        _switching = false;
        _loading = false;
      });
      return;
    }
    try {
      await _pool.openActive(_episodeId, previous);
      await _applySavedRate();
      if (position > Duration.zero) {
        try {
          await _seekWhenReady(position, episodeId: _episodeId);
        } on Object {
          // Resume from the start rather than fail the restore.
        }
      }
      if (playing) {
        try {
          await _engine.play();
        } on Object {
          // Best effort: the picture is already back.
        }
      }
    } on Object {
      // Fall through to the state reset.
    }
    if (!mounted) return;
    setState(() {
      _plan = previous;
      _quality = previous.bestStream?.quality ?? _quality;
      _switching = false;
      _loading = false;
    });
    _showNotice('该清晰度无法播放，已切回原清晰度');
  }

  Widget _downloadNotice(BuildContext context) {
    final tokens = AppTokens.of(context);
    return GestureDetector(
      onTap: _openDownloadsPage,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.x3,
          AppSpacing.x2,
          AppSpacing.x2,
          AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          // Flat fill over the video: a backdrop blur here had to be
          // recomputed on every frame while the picture was playing.
          color: Colors.black.withValues(alpha: 0.66),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
              ),
            ),
            child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.downloading,
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '已加入下载 · $_downloadQueued 集',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '查看',
              style: TextStyle(
                color: tokens.colors.accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
              IconButton(
                onPressed: () {
                  _downloadNoticeTimer?.cancel();
                  setState(() => _downloadQueued = 0);
                },
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 26, height: 26),
                icon: const Icon(Icons.close, size: 14, color: Colors.white54),
              ),
            ],
          ),
        ),
    );
  }

  // -------------------------------------------------------------- controls

  /// The overlay (info card + controls) belongs to pointer activity: once the
  /// mouse stops moving or leaves the page it goes away, playing or paused.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), _hideControls);
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!mounted || !_controlsVisible) return;
    setState(() => _controlsVisible = false);
  }

  void _showControls() {
    // A closed bottom sheet can leave focus on a dead node; hovering the
    // player takes it back so Space/Esc keep working.
    if (!_pageFocus.hasFocus) _pageFocus.requestFocus();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final snapshot = _engine.snapshot.value;
    if (snapshot.playing) {
      await _engine.pause();
      _saveProgress();
    } else {
      await _engine.play();
    }
    _showControls();
  }

  Future<void> _seekBy(int seconds) async {
    final snapshot = _engine.snapshot.value;
    final next = snapshot.position + Duration(seconds: seconds);
    await _engine.seek(next < Duration.zero ? Duration.zero : next);
  }

  Future<void> _changeVolume(double delta) async {
    final next = (_volume + delta).clamp(0.0, 1.0);
    _setVolume(next);
    if (next > 0) _lastVolume = next;
  }

  /// Applies and remembers the level; the write is debounced so dragging the
  /// slider does not hit the settings file on every tick.
  void _setVolume(double value) {
    final next = value.clamp(0.0, 1.0);
    _volume = next;
    unawaited(_engine.setVolume(next));
    final controller = AppScope.controllerOf(context);
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      unawaited(controller.updateSettings(
        controller.settings.copyWith(volume: next),
      ));
    });
  }

  Future<void> _toggleMute() async {
    final current = _volume;
    if (current > 0.001) {
      _lastVolume = current;
      _setVolume(0);
    } else {
      _setVolume(_lastVolume <= 0.001 ? 1 : _lastVolume);
    }
  }

  /// Sidebar playback vs whole-window playback, both inside the app.
  void _toggleWindowMaximized() {
    final mode = _windowMode;
    if (mode == null) return;
    setState(() => _windowMaximized = !_windowMaximized);
    mode.setMaximized(_windowMaximized);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    await WindowControls.setFullscreen(next);
    _appController?.setImmersive(next);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy.abs() < 1) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWheelMs < 320) return;
    _lastWheelMs = now;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _stepEpisode(dy > 0 ? 1 : -1);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _changeVolume(0.05);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _changeVolume(-0.05);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_windowMaximized) {
        _toggleWindowMaximized();
      } else if (_fullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PageTitleBinding(
      title: _episodeLabel.isEmpty
          ? _title
          : '${_title} · $_episodeLabel',
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _pageFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onHover: (_) => _showControls(),
            onExit: (_) => _hideControls(),
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlay,
                onDoubleTap: () {
                  final position = _engine.snapshot.value.position;
                  _engine.seek(position + const Duration(seconds: 10));
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The decoder shows black until the first frame lands:
                    // keep the artwork behind it so a switch never reads as
                    // a dead screen.
                    if (_cover.isNotEmpty)
                      Positioned.fill(
                        child: CoverImage(
                          url: _cover,
                          seed: _title,
                          fit: BoxFit.cover,
                          decodeWidth: 240,
                          blurSigma: 26,
                        ),
                      ),
                    _engine.buildSurface(context),
                    // While a new episode is opening, the engine still holds
                    // the previous frame. Cover it with the artwork and a
                    // loading mark instead of letting a stale picture sit
                    // there for seconds.
                    if (_switching || _loading)
                      Positioned.fill(
                        child: _SwitchCurtain(cover: _cover, title: _title),
                      ),
                    if (_danmakuOn && _danmaku.isNotEmpty && widget.api != null)
                      ListenableBuilder(
                        listenable: AppScope.controllerOf(context),
                        builder: (context, _) {
                          final style =
                              AppScope.controllerOf(context).settings;
                          return DanmakuLayer(
                            engine: _engine,
                            lines: _danmaku,
                            api: widget.api!,
                            itemId: _itemId,
                            episodeId: _episodeId,
                            onChanged: _loadDanmaku,
                            fontSize: style.danmakuFontSize,
                            opacity: style.danmakuOpacity,
                            speed: style.danmakuSpeed,
                          );
                        },
                      ),
                    ValueListenableBuilder<PlaybackSnapshot>(
                      valueListenable: _engine.snapshot,
                      builder: (context, snapshot, _) {
                        // No duration yet means the media never opened: show
                        // a spinner instead of a silent black frame.
                        final opened = snapshot.duration > Duration.zero;
                        final show = _loading ||
                            (snapshot.error == null &&
                                (snapshot.buffering || !opened));
                        if (!show) return const SizedBox.shrink();
                        return const IgnorePointer(child: LoadingOverlay());
                      },
                    ),
                    if (_error != null)
                      PlayerNotReady(
                        error: _error!,
                        onBack: () => Navigator.of(context).maybePop(),
                        onRetry: _retryCurrent,
                      ),
                    // Back button: the only chrome besides the controls.
                    Positioned(
                      left: AppSpacing.x2,
                      top: AppSpacing.x2,
                      child: SafeArea(
                        child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: AppDuration.overlay,
                          child: IconButton(
                            tooltip: '返回',
                            color: Colors.white,
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () =>
                                Navigator.of(context).maybePop(),
                          ),
                        ),
                      ),
                    ),
                    // Resume notice: frosted, top-centre, never over the
                    // progress bar or the controls.
                    if (_downloadQueued > 0)
                      Positioned(
                        right: AppSpacing.x4,
                        bottom: 120,
                        child: _downloadNotice(context),
                      ),
                    if (_notice != null)
                      Positioned(
                        top: 80,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.x4,
                                vertical: AppSpacing.x2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xB3000000),
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.md),
                                    border: Border.all(
                                      color: const Color(0x40FFFFFF),
                                    ),
                                  ),
                                  child: Text(
                                    _notice!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: AppFontSize.xs,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                    if (_item != null || _isLocal || _title.isNotEmpty)
                      Positioned(
                        left: AppSpacing.x4,
                        bottom: 116,
                        // Leaves room for the action rail on the right.
                        right: AppSpacing.x12 + AppSpacing.x4,
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: AnimatedOpacity(
                            opacity: _controlsVisible ? 1 : 0,
                            duration: AppDuration.overlay,
                            child: PlayerInfoCard(
                              item: _item ??
                                  Item(
                                    id: _itemId,
                                    title: _title,
                                    cover: _cover,
                                  ),
                              episodeLabel: _episodeLabel,
                              onOpenDetail: _openDetail,
                              local: _isLocal,
                            ),
                          ),
                        ),
                      ),
                    // 点赞 / 评论 / 收藏: the same rail the home feed uses.
                    // It only needs the ids, so the detail entry shows it even
                    // before /detail resolves.
                    if (widget.api != null && _itemId.isNotEmpty)
                      Positioned(
                        right: AppSpacing.x3,
                        bottom: 200,
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: AnimatedOpacity(
                            opacity: _controlsVisible ? 1 : 0,
                            duration: AppDuration.overlay,
                            child: SeriesActionRail(
                              api: widget.api!,
                              item: _item ??
                                  Item(
                                    id: _itemId,
                                    title: _title,
                                    cover: _cover,
                                    type: 'series',
                                  ),
                              episodeId: _episodeId,
                              stats: _episodeStats,
                              onLikeChanged: (liked, likeCount) {
                                setState(() {
                                  _likeOverrides[_episodeId] = (
                                    liked: liked,
                                    likeCount: likeCount,
                                  );
                                });
                              },
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: AppDuration.overlay,
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: _controls(context),
                        ),
                      ),
                    ),
                    // The speed menu lives in the page-level Stack: inside the
                    // controls row it would sit outside that Stack's bounds and
                    // could not be hit-tested, so moving onto it dismissed it.
                    if (_speedHover)
                      Positioned(
                        right: 112,
                        // Sits right above the speed button (the button row is
                        // ~64px tall from the page bottom).
                        bottom: 70,
                        child: SpeedPanel(
                          current: _engine.snapshot.value.rate,
                          onPick: (rate) {
                            _engine.setRate(rate);
                            _rememberRate(rate);
                            setState(() => _speedHover = false);
                          },
                          onEnter: () => _speedHideTimer?.cancel(),
                          onExit: () {
                            _speedHideTimer?.cancel();
                            _speedHideTimer =
                                Timer(const Duration(milliseconds: 350), () {
                              if (mounted) {
                                setState(() => _speedHover = false);
                              }
                            });
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The source only sends a sprite address, so the shell owns the layout:
  // the sheet is assumed to be a square grid of equally sized tiles.
  static const int _spriteCols = 10;
  static const Duration _spriteRetryAfter = Duration(seconds: 12);

  /// The seek bar can only draw a JPEG. A source sprite is downloaded and
  /// converted once; until it is ready the preview stays hidden.
  ThumbStrip? _stripFor(MediaPlan? plan) {
    final declared = plan?.thumbs;
    if (declared != null) return _declaredStrip(declared);
    final sprite = plan?.spriteUrl;
    if (sprite == null || !sprite.startsWith('http')) return _localThumbs;
    final image = _spriteFiles[sprite];
    if (image == null) {
      _requestSprite(sprite);
      return _localThumbs;
    }
    final tileWidth = image.width ~/ _spriteCols;
    final tileHeight = image.height ~/ _spriteCols;
    if (tileWidth <= 0 || tileHeight <= 0) return _localThumbs;
    return ThumbStrip(
      url: image.path,
      cols: _spriteCols,
      rows: _spriteCols,
      count: _spriteCols * _spriteCols,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
    );
  }

  /// Older sources may still describe their own grid; the address is
  /// converted the same way and their tile layout is kept.
  ThumbStrip? _declaredStrip(ThumbStrip strip) {
    if (!strip.url.startsWith('http')) return strip;
    final image = _spriteFiles[strip.url];
    if (image != null) {
      return ThumbStrip(
        url: image.path,
        cols: strip.cols,
        rows: strip.rows,
        count: strip.count,
        tileWidth: strip.tileWidth,
        tileHeight: strip.tileHeight,
        intervalSec: strip.intervalSec,
      );
    }
    _requestSprite(strip.url);
    return null;
  }

  /// Retries are spaced out rather than disabled: the seek preview asks again
  /// on every rebuild, so a failed sheet must not be re-requested per tick,
  /// but a transient CDN failure should heal instead of leaving the episode
  /// without thumbnails for the whole session.
  void _requestSprite(String url) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = _spriteRequestedAt[url];
    if (previous != null && now - previous < _spriteRetryAfter.inMilliseconds) {
      return;
    }
    _spriteRequestedAt[url] = now;
    RemoteSprite.ensure(url).then((image) {
      if (!mounted || image == null) return;
      setState(() => _spriteFiles[url] = image);
    });
  }

  Widget _controls(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: _engine.snapshot,
      builder: (context, snapshot, _) {
        final duration = snapshot.duration.inMilliseconds;
        final plan = _plan;
        final streams = plan?.streams ?? const <Stream>[];
        return Container(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.x4,
            AppSpacing.x2,
            AppSpacing.x4,
            AppSpacing.x4,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xE6000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      _format(snapshot.position),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: AppFontSize.xxs,
                      ),
                    ),
                    Expanded(
                      child: PlayerSeekBar(
                        value: duration <= 0
                            ? 0
                            : (snapshot.position.inMilliseconds / duration)
                                .clamp(0.0, 1.0),
                        position: snapshot.position,
                        duration: snapshot.duration,
                        thumbs: _stripFor(plan),
                        accent: tokens.colors.accent,
                        onChanged: duration <= 0
                            ? null
                            : (value) {
                                _engine.seek(
                                  Duration(
                                    milliseconds: (duration * value).round(),
                                  ),
                                );
                                _showControls();
                              },
                      ),
                    ),
                    Text(
                      _format(snapshot.duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: AppFontSize.xxs,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: snapshot.playing ? '暂停' : '播放',
                      color: Colors.white,
                      onPressed: snapshot.ready ? _togglePlay : null,
                      icon: Icon(
                        snapshot.playing ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一集',
                      color: Colors.white,
                      onPressed: _episodes.isEmpty
                          ? null
                          : () => _stepEpisode(1),
                      icon: const Icon(Icons.skip_next),
                    ),
                    if (_episodes.isNotEmpty)
                      Text(
                        _episodeCounter,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppFontSize.xs,
                        ),
                      ),
                    const Spacer(),
                    // 音量
                    IconButton(
                      tooltip: snapshot.volume <= 0.001 ? '取消静音' : '静音',
                      color: Colors.white,
                      onPressed: _toggleMute,
                      icon: Icon(
                        snapshot.volume <= 0.001
                            ? Icons.volume_off
                            : Icons.volume_up,
                      ),
                    ),
                    SizedBox(
                      width: 88,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: tokens.colors.accent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: snapshot.volume.clamp(0.0, 1.0),
                          onChanged: _setVolume,
                        ),
                      ),
                    ),
                    // 弹幕
                    IconButton(
                      tooltip: _danmakuOn ? '关闭弹幕' : '打开弹幕',
                      color: _danmakuOn
                          ? tokens.colors.accent
                          : Colors.white70,
                      onPressed: () =>
                          setState(() => _danmakuOn = !_danmakuOn),
                      icon: const Icon(Icons.subtitles_rounded),
                    ),
                    IconButton(
                      tooltip: '弹幕列表',
                      color: Colors.white70,
                      onPressed: _openDanmaku,
                      icon: const Icon(Icons.forum_outlined),
                    ),
                    IconButton(
                      tooltip: '下载',
                      color: Colors.white70,
                      onPressed: _openDownload,
                      icon: const Icon(Icons.download_outlined),
                    ),
                    // 清晰度：本地文件没有可选清晰度，也不显示源的占位值
                    if (!_isLocal)
                      TextButton(
                        onPressed: streams.isEmpty
                            ? null
                            : () => showQualitySheet(context, streams: streams, current: _quality, onSelected: _switchQuality),
                        child: Text(
                          _quality.isEmpty ? '清晰度' : _quality,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.xs,
                          ),
                        ),
                      ),
                    // 倍速：悬停即显示，不弹 modal
                    MouseRegion(
                      onEnter: (_) {
                        _speedHideTimer?.cancel();
                        setState(() => _speedHover = true);
                      },
                      onExit: (_) {
                        _speedHideTimer?.cancel();
                        _speedHideTimer =
                            Timer(const Duration(milliseconds: 350), () {
                          if (mounted) setState(() => _speedHover = false);
                        });
                      },
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _speedHover = !_speedHover),
                        child: Text(
                          '${snapshot.rate}×',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.xs,
                          ),
                        ),
                      ),
                    ),
                    // 选集
                    if (_episodes.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => showEpisodesDrawer(context, episodes: _episodes, currentId: _episodeId, watched: _watchedIds, onSelect: _playEpisode),
                        icon: const Icon(
                          Icons.list,
                          size: 18,
                          color: Colors.white,
                        ),
                        label: Text(
                          '选集',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.xs,
                          ),
                        ),
                      ),
                    // 作品系列（合集里有别的作品时才出现）
                    if (_albumItems.isNotEmpty)
                      TextButton.icon(
                        onPressed: _openAlbum,
                        icon: const Icon(
                          Icons.collections_bookmark_outlined,
                          size: 18,
                          color: Colors.white,
                        ),
                        label: Text(
                          '作品系列',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.xs,
                          ),
                        ),
                      ),
                    // 程序内最大化：隐藏侧边栏，占满整个窗口
                    if (widget.windowToggle && _windowMode != null)
                      IconButton(
                        tooltip: _windowMaximized ? '退出最大化' : '程序内最大化',
                        color: Colors.white,
                        onPressed: _toggleWindowMaximized,
                        icon: Icon(
                          _windowMaximized
                              ? Icons.close_fullscreen
                              : Icons.open_in_full,
                        ),
                      ),
                    // 全屏：最右侧
                    IconButton(
                      tooltip: _fullscreen ? '退出全屏' : '全屏',
                      color: Colors.white,
                      onPressed: _toggleFullscreen,
                      icon: Icon(
                        _fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }




  static String _format(Duration value) {
    final total = value.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Bullet lines driven by the playback position, so pausing and seeking keep
/// the layer in sync. Scroll lines cross the width in 8 seconds.


/// Hover card over the player: drama title (click → detail), current episode
/// and the series intro. Hidden together with the controls.


/// Right-side episode drawer: groups of 30 with a header per range and the
/// current episode scrolled into view on open.


/// Opaque cover used while a new episode opens, so the engine's previous
/// frame never shows under the new title.
class _SwitchCurtain extends StatelessWidget {
  const _SwitchCurtain({required this.cover, required this.title});

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
        const ColoredBox(color: Color(0x99000000)),
        const Center(child: LoadingMark()),
      ],
    );
  }
}
