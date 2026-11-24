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
import '../platform/platform.dart';
import '../player/bvc2_playback_engine.dart';
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
        fullWindow: true,
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
    this.fullWindow = false,
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

  /// Pushed above the shell as the only page: the window chrome floats on the
  /// video and must stay dark regardless of the page that opened it.
  final bool fullWindow;

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
  Timer? _noticeTimer;
  Timer? _thumbsTimer;
  String? _notice;
  Item? _item;
  List<Item> _albumItems = const [];
  bool _albumLoaded = false;
  bool _albumLoading = false;
  int _albumToken = 0;
  bool _controlsVisible = true;
  bool _loading = true;
  // True once this player has shown a frame. Repeat episode switches keep the
  // old picture instead of dropping a full-screen cover and spinner; only the
  // first open and a different work need the curtain.
  bool _hadFrame = false;
  // Timestamp of an episode open, so the switch-to-picture delay is visible
  // in logcat while tuning the decrypt proxy and player startup.
  DateTime? _switchStartedAt;
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
  bool _completedNoticeShown = false;
  bool _fullscreen = false;
  LocalWindowMode? _windowMode;
  bool _windowMaximized = false;
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

  /// bytevc2 (VVC) episodes have no decoder in the player: the core rebuilds
  /// them as H.264 on first play, which takes a few seconds. Say so instead of
  /// leaving a bare spinner that looks like a hang.
  String? get _preparingLabel {
    final plan = _plan;
    if (plan?.bestStream?.extra['rebuild'] == 'h264') {
      return '正在准备 H.264 副本，请稍候…';
    }
    final codec = (plan?.bestStream?.codec ?? '').toLowerCase();
    if (codec == 'bytevc2' || codec == 'bvc2' || codec == 'vvc') {
      return '该集为 VVC 编码，正在准备播放，请稍候…';
    }
    return null;
  }

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
    _engine.snapshot.addListener(_onSnapshot);
    // Prepare the next two episodes before the current one starts: a viewer
    // can hit "next" immediately, and the playlist then already has the
    // prefetched media.
    _prefetchNext(2);
    _switchStartedAt = DateTime.now();
    _start();
    _prefetchSprites();
    _scheduleHide();
    // Local persistence is not a per-second concern: pausing, switching and
    // closing all save explicitly. A slower tick also stops the two library
    // mutations from competing with playback.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      _saveProgress();
      _retryDanmakuIfNeeded();
    });
  }

  void _onSnapshot() {
    final snapshot = _engine.snapshot.value;
    if (!_hadFrame && _engine.position.value > Duration.zero) {
      setState(() => _hadFrame = true);
    }
    final switchStarted = _switchStartedAt;
    final position = _engine.position.value;
    if (switchStarted != null &&
        snapshot.playing &&
        position > Duration.zero &&
        position < const Duration(seconds: 5)) {
      _switchStartedAt = null;
      debugPrint(
        'player switch: first frame in '
        '${DateTime.now().difference(switchStarted).inMilliseconds} ms '
        '($_episodeLabel)',
      );
    }
    if (!snapshot.completed) _completedNoticeShown = false;
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
    // A playlist switch does not re-open the engine, so `ready` can stay
    // false while the new episode is already playing. The moving playhead is
    // the real proof that the switch landed; keeping `_switching` true here
    // made every later `completed` event get ignored, so auto-play-next
    // silently stopped after the first manual episode switch.
    if (_switching && _engine.position.value > Duration.zero) {
      _switchWatchdog?.cancel();
      _revertTo = null;
      setState(() => _switching = false);
      // Neighbour prefetch is deliberately deferred while a switch is in
      // flight; run it once the new episode actually has frames.
      _prefetchNext(3);
      // This tick still carries the previous item's completed flag on a
      // playlist switch; ignore it instead of advancing a second time.
      return;
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
      final window = _engine.position.value.inSeconds ~/ 30;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (window != _danmakuWindow && now - _lastDanmakuLoadMs > 2000) {
        _lastDanmakuLoadMs = now;
        _loadDanmaku();
      }
    }
    // A playlist switch can still report the previous item's completed flag
    // for a frame; never treat that as a second end-of-episode.
    if (!snapshot.completed || _advancing || _switching) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0 || index + 1 >= _episodes.length) return;
    // Watched to the end: [_saveProgress] stores it as finished with a zero
    // resume position, so selecting it again starts from the beginning.
    if (!AppScope.controllerOf(context).settings.autoPlayNext) {
      if (!_completedNoticeShown) {
        _completedNoticeShown = true;
        _showNotice('本集已播完');
      }
      return;
    }
    _advancing = true;
    _stepEpisode(1).whenComplete(() => _advancing = false);
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
    _noticeTimer?.cancel();
    _switchWatchdog?.cancel();
    _thumbsTimer?.cancel();
    _volumeSaveTimer?.cancel();
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
      var seconds = await library.episodeResumePosition(_seriesKey, episodeId);
      if (seconds < 5) {
        final history = await library.history();
        for (final row in history) {
          if (row.seriesKey != _seriesKey) continue;
          if (row.episodeId.isNotEmpty && row.episodeId != episodeId) break;
          // A finished work has no resume point even if an older build
          // stored its end position in the history row.
          if (row.finished ||
              (row.durationSec > 0 &&
                  row.positionSec >= row.durationSec - 5)) {
            break;
          }
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
      final seconds =
          await library.episodeResumePosition(_seriesKey, episodeId);
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
    final position = completed ? snapshot.duration : _engine.position.value;
    // A freshly opened episode starts at zero; without this guard the first
    // tick would replace a real position from an earlier session with 0s.
    if (!completed && position.inSeconds < 5) return;
    try {
      await library.recordPlayback(
        LibraryRecord(
          seriesKey: _seriesKey,
          title: _title,
          cover: _cover.isNotEmpty ? _cover : (_item?.cover ?? ''),
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
        // A finished episode stays marked as watched, but never as a resume
        // point: writing the end position here made selecting it seek to the
        // last three seconds and immediately auto-advance again.
        resumePositionSec: completed ? 0 : position.inSeconds,
        resumeDurationSec: snapshot.duration.inSeconds,
        completed: completed,
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
      // The first album lookup runs before the detail payload (and its
      // album_id) is known. Retry with the id now, so a slow detail response
      // does not leave 作品系列 empty.
      if (_albumItems.isEmpty && !_albumLoaded) unawaited(_loadAlbum());
    } on Object {
      // The hover card is optional.
    }
  }

  /// 作品系列 runs on its own: the season search takes seconds upstream, and
  /// waiting for /detail first would only add to that.
  Future<void> _loadAlbum() async {
    final api = widget.api;
    if (api == null || _itemId.isEmpty || _albumLoaded || _albumLoading) return;
    _albumLoading = true;
    final token = ++_albumToken;
    final albumId = (_item?.extra['album_id'] ?? '').toString();
    // The upstream season lookup can time out once and still succeed on the
    // next call. One failed request used to hide 作品系列 for the whole
    // session, which is why the tab appeared only sometimes.
    final attempts =
        albumId.isNotEmpty || _item?.extra['multi_season'] == true ? 3 : 2;
    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          final page = await api.album(_itemId, albumId: albumId);
          if (!mounted || token != _albumToken) return;
          if (page.items.isNotEmpty) {
            setState(() => _albumItems = page.items);
            _albumLoaded = true;
            return;
          }
        } on Object {
          // Retry below; a permanent absence simply leaves the entry hidden.
        }
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
          if (!mounted) return;
        }
      }
      // Allow a later _loadInfo to retry with the album id from the detail
      // payload instead of keeping the feature hidden forever.
      _albumLoaded = false;
    } finally {
      if (token == _albumToken) _albumLoading = false;
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
    // Do not let the previous work's prefetch queue delay the new one.
    _prefetchToken++;
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _loading = true;
      // A different work has different artwork; do not keep the previous
      // drama's last frame under it.
      _hadFrame = false;
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
                quality: savedQuality.isEmpty ? 'auto' : savedQuality,
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
        _albumLoading = false;
        _albumToken++;
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
      final position = _engine.position.value;
      if (position > Duration.zero) return;
      if (snapshot.error != null) return;
      debugPrint(
        'player watchdog: pos=${position.inMilliseconds}ms '
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
    final resumeAt = _engine.position.value;
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
  /// Preview strips are parked for now: building one decodes the episode once
  /// per tile, and a VVC episode has no hardware decoder, so the strip cost
  /// more than the playback. Flip back to true to restore them.
  static const bool _thumbnailsEnabled = false;

  /// VVC has no hardware decoder here, so sampling one preview frame per tile
  /// means decoding VVC twenty times while the episode plays — that is what
  /// pinned the CPU. Those episodes get no preview strip and never run ffmpeg.
  static bool _isVvcCodec(String? codec) {
    switch ((codec ?? '').toLowerCase()) {
      case 'bytevc2':
      case 'bvc2':
      case 'vvc':
        return true;
    }
    return false;
  }

  void _deferThumbs(MediaPlan plan) {
    _thumbsTimer?.cancel();
    _thumbsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !identical(_plan, plan)) return;
      _loadGeneratedThumbs(plan);
    });
  }

  void _loadGeneratedThumbs(MediaPlan plan) {
    if (!_thumbnailsEnabled) return;
    // A declared or plain sprite address is already the source's own artwork.
    if (plan.thumbs != null || plan.spriteUrl != null) return;
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) return;
    if (_isVvcCodec(stream.codec)) return;
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
    if (!_thumbnailsEnabled) return;
    if (_isVvcCodec(_plan?.bestStream?.codec)) return;
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
    bool skipWarm = false,
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
        skipWarm: skipWarm,
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
      // The first picture must win the CPU: converting a sprite while the
      // decoder is opening the stream is perceived as a stutter. After the
      // plan warm-up chain has started, `_planFor` below hits its cache and
      // does not kick a second gateway preparation job.
      await Future<void>.delayed(const Duration(seconds: 10));
      while (cursor < queue.length) {
        if (!mounted || token != _spriteToken) return;
        final id = queue[cursor++];
        try {
          // The neighbor plan is cached by _prefetchNext; reuse it instead of
          // issuing a second /play that would warm the same episode again.
          final plan = await _planFor(id, skipWarm: true);
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

    unawaited(worker());
  }

  /// Resolves the next episodes in the background; the gateway warms their
  /// media index in the same call. Only the immediate next one is opened in a
  /// spare engine, and only after the current episode settled: preloading two
  /// more streams at the instant of a switch is what made the switch stutter.
  int _prefetchToken = 0;

  /// Warms the next episodes' plans in order. The gateway starts preparing a
  /// bytevc2 episode on every `/play` (H.264 rebuild or lossless VVC remux), so
  /// sequential requests put the nearest episode into that queue first instead
  /// of leaving the order to a burst of parallel calls.
  ///
  /// No spare player is opened — the single engine opens the stream when the
  /// switch actually happens. This is what prepares episode 3 while episode 1
  /// is still playing.
  void _prefetchNext(int count) {
    if (_episodes.isEmpty) return;
    final index = _episodes.indexWhere((episode) => episode.id == _episodeId);
    if (index < 0) return;
    final controller = AppScope.controllerOf(context);
    // A local core prepares the next two episodes: one for auto-play, one so
    // a quick "next, next" still has media ready. A remote gateway may warm
    // the full configured window.
    final limit =
        controller.activeSourceRunsLocally ? (count < 2 ? count : 2) : count;
    final token = ++_prefetchToken;
    final episodes = _episodes;
    final quality = _quality;
    unawaited(() async {
      // Start almost immediately: switching right after an episode opens must
      // also find a queued entry. A short pause keeps it behind the first
      // frame's own request.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      for (var i = index + 1; i <= index + limit && i < episodes.length; i++) {
        if (!mounted || token != _prefetchToken || quality != _quality) return;
        final id = episodes[i].id;
        if (!_warming.add(id)) continue;
        try {
          // The next two episodes get their media prepared; the rest only
          // need a plan.
          final plan = await _planFor(id, skipWarm: i > index + 2);
          _warmProxy(plan);
          if (i == index + 1 && mounted && token == _prefetchToken) {
            // Put it in the player's own playlist: libmpv prefetches this
            // entry, so the switch does not rebuild the video output.
            await _engine.queueNext(plan);
          }
        } on Object {
          // Leave the next run free to retry this episode.
        } finally {
          _warming.remove(id);
        }
        // Space the jobs out: the gateway prepares one bytevc2 episode at a
        // time, and gaps keep the one on screen ahead of the queue.
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }());
  }

  /// Builds the decryption proxy for an episode that is only queued: opening
  /// it does a size probe and fetches the moov window from the CDN, and doing
  /// that while the current episode plays removes it from the switch.
  void _warmProxy(MediaPlan plan) {
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) return;
    // VVC decrypts inside the player process; only the mpv path needs the
    // loopback proxy warmed.
    if (Bvc2PlaybackEngine.handlesPlan(plan)) {
      Bvc2PlaybackEngine.warm(plan);
      return;
    }
    final decryption = stream.decryption ?? plan.decryption;
    if (!decryption.required ||
        decryption.location != 'client' ||
        decryption.keyHex.isEmpty) {
      return;
    }
    DecryptProxy.warm(stream.url, decryption.keyHex);
  }

  Future<void> _playEpisode(Episode episode) async {
    if (episode.id == _episodeId) return;
    // Rapid scrolling can start a second switch while the first is still
    // fetching; only the latest one may touch the engine or the page state.
    final token = ++_episodeToken;
    _switchStartedAt = DateTime.now();
    // The old chain would otherwise keep warming the episode we just left.
    _prefetchToken++;
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
      // The next episode is normally already in libmpv's playlist. Advancing
      // there keeps the video output alive and plays the prefetched file.
      final queuedId = plan.episodeId.isNotEmpty ? plan.episodeId : episode.id;
      var advanced = localPath == null &&
          await _engine.playQueuedNext(queuedId);
      if (!mounted || token != _episodeToken) return;
      if (!advanced && localPath == null) {
        // Switching immediately after playback starts means the prefetcher
        // has not queued this episode yet. Append it now and jump inside the
        // playlist anyway: open() clears the video output, which is exactly
        // the black frame the viewer sees in this case.
        await _engine.queueNext(plan);
        advanced = await _engine.playQueuedNext(queuedId);
        if (!mounted || token != _episodeToken) return;
      }
      if (!advanced) {
        final adopted = await _pool.adopt(episode.id);
        if (!mounted || token != _episodeToken) return;
        if (!adopted) {
          await _pool.openActive(episode.id, plan);
          await _engine.play();
          if (!mounted || token != _episodeToken) return;
        }
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
      final offset = _engine.position.value.inSeconds;
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
      positionSec: _engine.position.value.inSeconds,
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
        durationMs: plan.durationMs,
        extra: plan.extra,
      );
      // Preparing the plan takes seconds and the picture keeps playing: read
      // the live state again so the new stream resumes where it actually is,
      // not where it was when the quality sheet was opened.
      final resumeAt = _engine.position.value;
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
          color: tokens.colors.glassStrong,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: tokens.colors.glassStrongBorder),
        ),
            child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.downloading,
              size: 18,
              color: tokens.colors.text2,
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '已加入下载 · $_downloadQueued 集',
              style: TextStyle(
                color: tokens.colors.text,
                fontSize: AppFontSize.body,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '查看',
              style: TextStyle(
                color: tokens.colors.accent,
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              tooltip: '关闭',
              onPressed: () {
                _downloadNoticeTimer?.cancel();
                setState(() => _downloadQueued = 0);
              },
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints.tightFor(width: 26, height: 26),
              icon: Icon(
                Icons.close,
                size: 14,
                color: tokens.colors.text3,
              ),
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
    final next = _engine.position.value + Duration(seconds: seconds);
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
      _showNotice('已静音');
    } else {
      _setVolume(_lastVolume <= 0.001 ? 1 : _lastVolume);
      _showNotice('已取消静音');
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
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(10);
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
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
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
    final tokens = AppTokens.of(context);
    return PageTitleBinding(
      title: _episodeLabel.isEmpty
          ? _title
          : '${_title} · $_episodeLabel',
      overVideo: widget.fullWindow,
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
                // On phones the feed switches episodes by swiping up/down;
                // the full player follows the same convention.
                onVerticalDragEnd: (details) {
                  if (!isMobilePlatform) return;
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -200) {
                    _stepEpisode(1);
                  } else if (velocity > 200) {
                    _stepEpisode(-1);
                  }
                },
                // Desktop players use double-click for fullscreen; ±10 s is
                // on explicit buttons and the arrow keys instead.
                onDoubleTap: () {
                  _toggleFullscreen();
                },
                onSecondaryTapUp: (details) =>
                    _showVideoMenu(details.globalPosition),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The decoder shows black until the first frame lands:
                    // keep the artwork behind it so a switch never reads as
                    // a dead screen.
                    if (_cover.isNotEmpty)
                      Positioned.fill(
                        child: ListenableBuilder(
                          listenable: Listenable.merge(
                            [_engine.snapshot, _engine.position],
                          ),
                          builder: (context, child) {
                            // A full-screen 26px blur behind the video is
                            // re-composited with every frame; once a picture is
                            // on screen the artwork adds nothing but cost.
                            final snapshot = _engine.snapshot.value;
                            final covered = snapshot.ready &&
                                (snapshot.playing ||
                                    _engine.position.value > Duration.zero);
                            if (covered) return const SizedBox.shrink();
                            return child!;
                          },
                          child: CoverImage(
                            url: _cover,
                            seed: _title,
                            fit: BoxFit.cover,
                            decodeWidth: 240,
                            blurSigma: 26,
                          ),
                        ),
                      ),
                    // The video texture is its own layer: control fades and
                    // danmaku repaints do not force the picture to repaint.
                    RepaintBoundary(child: _engine.buildSurface(context)),
                    // Only the first frame (or a different work) needs the
                    // full cover. Switching episodes keeps the previous
                    // picture until the new one paints, which is what makes
                    // the hand-off feel continuous.
                    if ((_switching || _loading) && !_hadFrame)
                      Positioned.fill(
                        child: _SwitchCurtain(cover: _cover, title: _title),
                      ),
                    if (_danmakuOn && _danmaku.isNotEmpty && widget.api != null)
                      ListenableBuilder(
                        listenable: AppScope.controllerOf(context),
                        builder: (context, _) {
                          final style =
                              AppScope.controllerOf(context).settings;
                          return RepaintBoundary(
                            child: DanmakuLayer(
                              engine: _engine,
                              lines: _danmaku,
                              api: widget.api!,
                              itemId: _itemId,
                              episodeId: _episodeId,
                              onChanged: _loadDanmaku,
                              fontSize: style.danmakuFontSize,
                              opacity: style.danmakuOpacity,
                              speed: style.danmakuSpeed,
                            ),
                          );
                        },
                      ),
                    ValueListenableBuilder<PlaybackSnapshot>(
                      valueListenable: _engine.snapshot,
                      builder: (context, snapshot, _) {
                        // A growing remuxed stream can report no duration even
                        // after frames are on screen. A moving playhead or a
                        // painted frame proves playback started, so do not
                        // leave the spinner over a playing picture just
                        // because `duration` is still zero.
                        final hasPicture = _hadFrame ||
                            _engine.position.value > Duration.zero;
                        final show = _loading ||
                            (snapshot.error == null && !hasPicture);
                        if (!show) return const SizedBox.shrink();
                        return IgnorePointer(
                          child: DelayedVisible(
                            visible: show,
                            delay: _hadFrame
                                ? const Duration(milliseconds: 800)
                                : Duration.zero,
                            child: LoadingOverlay(label: _preparingLabel),
                          ),
                        );
                      },
                    ),
                    if (_error != null)
                      PlayerNotReady(
                        error: _error!,
                        onBack: () => Navigator.of(context).maybePop(),
                        onRetry: _retryCurrent,
                      ),
                    // Back button: the only chrome besides the controls. In
                    // whole-window local playback the transparent title bar
                    // floats above the player, so clear its drag strip.
                    Positioned(
                      left: AppSpacing.x2,
                      top: AppSpacing.x2 +
                          (_windowMaximized ? AppSizes.titleBar : 0),
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
                    // Download and status notices cross-fade instead of
                    // popping in and out.
                    Positioned(
                      right: AppSpacing.x4,
                      bottom: 132,
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        child: AnimatedSwitcher(
                          duration: AppDuration.overlay,
                          switchInCurve: AppDuration.ease,
                          switchOutCurve: AppDuration.ease,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.2),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          ),
                          child: _downloadQueued > 0
                              ? _downloadNotice(context)
                              : const SizedBox.shrink(
                                  key: ValueKey('no-download-notice'),
                                ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 76,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: AppDuration.overlay,
                            switchInCurve: AppDuration.ease,
                            switchOutCurve: AppDuration.ease,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, -0.2),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: _notice == null
                                ? const SizedBox.shrink(
                                    key: ValueKey('no-notice'),
                                  )
                                : Container(
                                    key: ValueKey(_notice),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.x4,
                                      vertical: AppSpacing.x2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.colors.glassStrong,
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.md,
                                      ),
                                      border: Border.all(
                                        color: tokens.colors.glassStrongBorder,
                                      ),
                                    ),
                                    child: Text(
                                      _notice!,
                                      style: TextStyle(
                                        color: tokens.colors.text,
                                        fontSize: AppFontSize.xs,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    // The title card, action rail and transport bar are one
                    // bottom-anchored surface: a single fade + slide, one
                    // scrim, and no absolute offsets that drift when the
                    // window changes shape.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedSlide(
                        offset: _controlsVisible
                            ? Offset.zero
                            : const Offset(0, 0.03),
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                          child: IgnorePointer(
                            ignoring: !_controlsVisible,
                            child: RepaintBoundary(
                              // Resting on a control must not let the idle
                              // timer hide the bar under the pointer.
                              child: MouseRegion(
                                onEnter: (_) => _hideTimer?.cancel(),
                                onExit: (_) => _scheduleHide(),
                                child: _bottomChrome(context),
                              ),
                            ),
                          ),
                        ),
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

  /// Right-click on the picture: the operations a desktop player is expected
  /// to expose without moving the pointer to the control bar.
  Future<void> _showVideoMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = overlay.globalToLocal(globalPosition);
    final playing = _engine.snapshot.value.playing;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'play', child: Text(playing ? '暂停' : '播放')),
        PopupMenuItem(
          value: 'full',
          child: Text(_fullscreen ? '退出全屏' : '全屏'),
        ),
        if (_episodes.isNotEmpty)
          const PopupMenuItem(value: 'episodes', child: Text('选集')),
        if (widget.api != null && _itemId.isNotEmpty)
          const PopupMenuItem(value: 'detail', child: Text('详情')),
        if (isDesktopPlatform && widget.windowToggle && _windowMode != null)
          PopupMenuItem(
            value: 'window',
            child: Text(_windowMaximized ? '退出最大化' : '程序内最大化'),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'copy', child: Text('复制标题')),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        unawaited(_togglePlay());
      case 'full':
        unawaited(_toggleFullscreen());
      case 'episodes':
        showEpisodesDrawer(
          context,
          episodes: _episodes,
          currentId: _episodeId,
          watched: _watchedIds,
          onSelect: _playEpisode,
        );
      case 'detail':
        unawaited(_openDetail());
      case 'window':
        _toggleWindowMaximized();
      case 'copy':
        unawaited(Clipboard.setData(ClipboardData(text: _title)));
        _showNotice('已复制标题');
    }
  }

  /// One bottom surface: title card + action rail above the transport bar, so
  /// the chrome moves as a unit and a single scrim covers everything drawn
  /// over the picture.
  Widget _bottomChrome(BuildContext context) {
    final showInfo = _item != null || _isLocal || _title.isNotEmpty;
    // On short windows the rail would cover the picture; the transport bar
    // and title card carry enough context on their own.
    final showRail = widget.api != null &&
        _itemId.isNotEmpty &&
        MediaQuery.sizeOf(context).height >= 620;
    return DecoratedBox(
      decoration: const BoxDecoration(
        // The scrim only needs to carry the transport row: keep the upper part
        // almost clear and stop well short of opaque black.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0x1A000000),
            Color(0x73000000),
            Color(0xB3000000),
          ],
          stops: [0, 0.45, 0.78, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showInfo || showRail)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  AppSpacing.x8,
                  AppSpacing.x3,
                  AppSpacing.x2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (showInfo)
                      Expanded(
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
                    if (showRail) ...[
                      const SizedBox(width: AppSpacing.x4),
                      SeriesActionRail(
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
                    ],
                  ],
                ),
              ),
            _controls(context),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: _engine.snapshot,
      builder: (context, snapshot, _) {
        final duration = snapshot.duration.inMilliseconds;
        final plan = _plan;
        final streams = plan?.streams ?? const <Stream>[];
        final index =
            _episodes.indexWhere((episode) => episode.id == _episodeId);
        final hasPrevious = index > 0;
        final hasNext = index >= 0 && index + 1 < _episodes.length;
        return LayoutBuilder(
          builder: (context, constraints) {
            final roomy = constraints.maxWidth >= 620;
            final wide = constraints.maxWidth >= 900;
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x4,
                0,
                AppSpacing.x2,
                AppSpacing.x2,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Only this row follows the playhead; the rest of the bar
                  // stays on the coarse snapshot.
                  ValueListenableBuilder<Duration>(
                    valueListenable: _engine.position,
                    builder: (context, position, _) {
                      return Row(
                        children: [
                          Text(
                            _format(position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppFontSize.xxs,
                            ),
                          ),
                          Expanded(
                            child: PlayerSeekBar(
                              value: duration <= 0
                                  ? 0
                                  : (position.inMilliseconds / duration)
                                      .clamp(0.0, 1.0),
                              position: position,
                              duration: snapshot.duration,
                              buffered: snapshot.buffered,
                              thumbs: _stripFor(plan),
                              accent: tokens.colors.accent,
                              onChanged: duration <= 0
                                  ? null
                                  : (value) {
                                      _engine.seek(
                                        Duration(
                                          milliseconds:
                                              (duration * value).round(),
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
                      );
                    },
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '上一集',
                        color: Colors.white,
                        onPressed:
                            hasPrevious ? () => _stepEpisode(-1) : null,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      if (roomy)
                        IconButton(
                          tooltip: '后退 10 秒 (←)',
                          color: Colors.white,
                          onPressed: () => _seekBy(-10),
                          icon: const Icon(Icons.replay_10),
                        ),
                      IconButton(
                        tooltip: snapshot.playing ? '暂停 (空格)' : '播放 (空格)',
                        color: Colors.white,
                        iconSize: 32,
                        onPressed: snapshot.ready ? _togglePlay : null,
                        icon: Icon(
                          snapshot.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      if (roomy)
                        IconButton(
                          tooltip: '前进 10 秒 (→)',
                          color: Colors.white,
                          onPressed: () => _seekBy(10),
                          icon: const Icon(Icons.forward_10),
                        ),
                      IconButton(
                        tooltip: '下一集',
                        color: Colors.white,
                        onPressed: hasNext ? () => _stepEpisode(1) : null,
                        icon: const Icon(Icons.skip_next),
                      ),
                      if (roomy && _episodes.isNotEmpty)
                        Text(
                          _episodeCounter,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.xs,
                          ),
                        ),
                      const Spacer(),
                      IconButton(
                        tooltip: _danmakuOn ? '关闭弹幕' : '打开弹幕',
                        color: _danmakuOn
                            ? tokens.colors.accent
                            : Colors.white70,
                        onPressed: () =>
                            setState(() => _danmakuOn = !_danmakuOn),
                        icon: const Icon(Icons.subtitles_rounded),
                      ),
                      if (wide && _episodes.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => showEpisodesDrawer(
                            context,
                            episodes: _episodes,
                            currentId: _episodeId,
                            watched: _watchedIds,
                            onSelect: _playEpisode,
                          ),
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
                      if (wide)
                        PopupMenuButton<double>(
                          tooltip: '倍速',
                          color: tokens.colors.surface2,
                          onSelected: (rate) {
                            _engine.setRate(rate);
                            _rememberRate(rate);
                            _showNotice('${rate}× 倍速');
                          },
                          itemBuilder: (context) => [
                            for (final rate in const [
                              0.5,
                              0.75,
                              1.0,
                              1.25,
                              1.5,
                              2.0,
                            ])
                              PopupMenuItem<double>(
                                value: rate,
                                child: Row(
                                  children: [
                                    Text(
                                      '${rate}×',
                                      style: TextStyle(
                                        fontSize: AppFontSize.xs,
                                        color: (rate - snapshot.rate).abs() <
                                                0.001
                                            ? tokens.colors.accent
                                            : tokens.colors.text2,
                                      ),
                                    ),
                                    const Spacer(),
                                    if ((rate - snapshot.rate).abs() < 0.001)
                                      Icon(
                                        Icons.check,
                                        size: 14,
                                        color: tokens.colors.accent,
                                      ),
                                  ],
                                ),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.x2,
                              vertical: AppSpacing.x3,
                            ),
                            child: Text(
                              '${snapshot.rate}×',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: AppFontSize.xs,
                              ),
                            ),
                          ),
                        ),
                      // 清晰度：本地文件没有可选清晰度
                      if (wide && !_isLocal)
                        TextButton(
                          onPressed: streams.isEmpty
                              ? null
                              : () => showQualitySheet(
                                    context,
                                    streams: streams,
                                    current: _quality,
                                    onSelected: _switchQuality,
                                  ),
                          child: Text(
                            _quality.isEmpty ? '清晰度' : _quality,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppFontSize.xs,
                            ),
                          ),
                        ),
                      _moreMenu(
                        context,
                        compact: !wide,
                        streams: streams,
                      ),
                      _PlayerVolumeControl(
                        volume: snapshot.volume,
                        showSlider: roomy,
                        onChanged: _setVolume,
                        onToggleMute: _toggleMute,
                      ),
                      IconButton(
                        tooltip: _fullscreen ? '退出全屏 (F)' : '全屏 (F)',
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
            );
          },
        );
      },
    );
  }

  Widget _moreMenu(
    BuildContext context, {
    required bool compact,
    required List<Stream> streams,
  }) {
    final tokens = AppTokens.of(context);
    return PopupMenuButton<_PlayerMenuAction>(
      tooltip: '更多',
      color: tokens.colors.surface2,
      onSelected: (action) {
        switch (action) {
          case _PlayerMenuAction.quality:
            showQualitySheet(
              context,
              streams: streams,
              current: _quality,
              onSelected: _switchQuality,
            );
          case _PlayerMenuAction.speed:
            unawaited(_pickSpeed());
          case _PlayerMenuAction.episodes:
            showEpisodesDrawer(
              context,
              episodes: _episodes,
              currentId: _episodeId,
              watched: _watchedIds,
              onSelect: _playEpisode,
            );
          case _PlayerMenuAction.danmaku:
            unawaited(_openDanmaku());
          case _PlayerMenuAction.download:
            unawaited(_openDownload());
          case _PlayerMenuAction.album:
            unawaited(_openAlbum());
          case _PlayerMenuAction.windowMax:
            _toggleWindowMaximized();
          case _PlayerMenuAction.copyTitle:
            unawaited(Clipboard.setData(ClipboardData(text: _title)));
            _showNotice('已复制标题');
        }
      },
      itemBuilder: (context) => [
        if (compact && !_isLocal)
          PopupMenuItem(
            value: _PlayerMenuAction.quality,
            enabled: streams.isNotEmpty,
            child: _menuRow(
              context,
              Icons.high_quality_outlined,
              '清晰度',
              _quality.isEmpty ? '自动' : _quality,
            ),
          ),
        if (compact)
          PopupMenuItem(
            value: _PlayerMenuAction.speed,
            child: _menuRow(
              context,
              Icons.speed_rounded,
              '倍速',
              '${_engine.snapshot.value.rate}×',
            ),
          ),
        if (compact && _episodes.isNotEmpty)
          PopupMenuItem(
            value: _PlayerMenuAction.episodes,
            child: _menuRow(
              context,
              Icons.list,
              '选集',
              _episodeCounter,
            ),
          ),
        PopupMenuItem(
          value: _PlayerMenuAction.danmaku,
          enabled: widget.api != null,
          child: _menuRow(context, Icons.forum_outlined, '弹幕列表', ''),
        ),
        PopupMenuItem(
          value: _PlayerMenuAction.download,
          enabled: !_isLocal && _episodes.isNotEmpty && widget.api != null,
          child: _menuRow(context, Icons.download_outlined, '下载', ''),
        ),
        if (_albumItems.isNotEmpty)
          PopupMenuItem(
            value: _PlayerMenuAction.album,
            child: _menuRow(
              context,
              Icons.collections_bookmark_outlined,
              '作品系列',
              '',
            ),
          ),
        if (isDesktopPlatform && widget.windowToggle && _windowMode != null)
          PopupMenuItem(
            value: _PlayerMenuAction.windowMax,
            child: _menuRow(
              context,
              _windowMaximized
                  ? Icons.close_fullscreen
                  : Icons.open_in_full,
              _windowMaximized ? '退出最大化' : '程序内最大化',
              '',
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PlayerMenuAction.copyTitle,
          child: _menuRow(context, Icons.copy_rounded, '复制标题', ''),
        ),
      ],
      child: SizedBox(
        width: 38,
        height: 40,
        child: Icon(Icons.more_horiz, color: tokens.colors.text2),
      ),
    );
  }

  Widget _menuRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: tokens.colors.text2),
        const SizedBox(width: AppSpacing.x2),
        Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.xs,
            color: tokens.colors.text,
          ),
        ),
        if (value.isNotEmpty) ...[
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: AppFontSize.xxs,
              color: tokens.colors.text3,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickSpeed() async {
    final current = _engine.snapshot.value.rate;
    final picked = await showDialog<double>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('播放速度'),
        children: [
          for (final rate in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(rate),
              child: Row(
                children: [
                  Text('${rate}×'),
                  const Spacer(),
                  if ((rate - current).abs() < 0.001)
                    const Icon(Icons.check, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _engine.setRate(picked);
    _rememberRate(picked);
    _showNotice('${picked}× 倍速');
  }




  static String _format(Duration value) {
    final total = value.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

enum _PlayerMenuAction {
  quality,
  speed,
  episodes,
  danmaku,
  download,
  album,
  windowMax,
  copyTitle,
}

/// Mute button plus a volume slider that only becomes visible while the
/// pointer is over the group. The slider keeps its space so the row never
/// shifts when it appears.
class _PlayerVolumeControl extends StatefulWidget {
  const _PlayerVolumeControl({
    required this.volume,
    required this.showSlider,
    required this.onChanged,
    required this.onToggleMute,
  });

  final double volume;
  final bool showSlider;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  State<_PlayerVolumeControl> createState() => _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends State<_PlayerVolumeControl> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final mute = widget.volume <= 0.001;
    final visible = _hovering || _dragging;
    final slider = SizedBox(
      width: 84,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: SliderComponentShape.noOverlay,
          activeTrackColor: tokens.colors.accent,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
        ),
        child: Slider(
          value: widget.volume.clamp(0.0, 1.0),
          onChangeStart: (_) => setState(() => _dragging = true),
          onChanged: widget.onChanged,
          onChangeEnd: (_) => setState(() => _dragging = false),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: mute ? '取消静音 (M)' : '静音 (M)',
            color: Colors.white,
            onPressed: widget.onToggleMute,
            icon: Icon(mute ? Icons.volume_off : Icons.volume_up),
          ),
          if (widget.showSlider)
            AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: AppDuration.micro,
              curve: AppDuration.ease,
              child: IgnorePointer(
                ignoring: !visible,
                child: ExcludeFocus(excluding: !visible, child: slider),
              ),
            ),
        ],
      ),
    );
  }
}

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
          // A full-screen 26 px blur used to be composited on every switch,
          // exactly while the new stream was starting. The small cover
          // already reads as a soft backdrop without the filter.
          CoverImage(
            url: cover,
            seed: title,
            fit: BoxFit.cover,
            decodeWidth: 240,
          ),
        const ColoredBox(color: Color(0x99000000)),
        const Center(child: LoadingMark()),
      ],
    );
  }
}
