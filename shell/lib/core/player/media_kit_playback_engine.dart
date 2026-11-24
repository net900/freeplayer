import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../decryptor/decrypt_proxy.dart';
import '../logging/app_log.dart';
import '../sp/models.dart';
import 'playback_coordinator.dart';
import 'playback_engine.dart';

/// media_kit (libmpv) adapter for the playback contract. The engine owns the
/// player and the video surface; pages only see [snapshot] and [buildSurface].
class MediaKitPlaybackEngine implements PlaybackEngine {
  /// libmpv is loaded on first use, not at app start: initialising it costs
  /// memory that a session which never opens a video should not pay.
  static bool _mediaKitReady = false;

  static void _ensureMediaKit() {
    if (_mediaKitReady) return;
    _mediaKitReady = true;
    MediaKit.ensureInitialized();
  }

  static Player _createPlayer() {
    _ensureMediaKit();
    return Player();
  }

  MediaKitPlaybackEngine({this.fit = BoxFit.cover})
      : _player = _createPlayer() {
    // `hwdec=auto` may pick a decoder that decodes audio but never produces a
    // picture; auto-safe only uses hardware paths known to render correctly
    // and falls back to software otherwise.
    // Fixed output size: the vendored media_kit_video then keeps one Flutter
    // texture for the whole session. Source episodes report slightly
    // different sizes (e.g. 1882x1080 then 1920x1080); resizing the texture
    // for each one produced the black frame during every episode switch.
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'auto-safe',
        width: 1920,
        height: 1080,
      ),
    );
    _tuned = _tune();
    PlaybackCoordinator.instance.register(this, _pauseForCoordinator);
    _subscriptions.add(_player.stream.buffering.listen((value) {
      _set(buffering: value);
    }));
    // Buffered position drives the second, dimmer track on the seek bar.
    // mpv emits it far more often than the bar needs, so only publish a change
    // of at least one second.
    _subscriptions.add(_player.stream.buffer.listen((value) {
      if ((value - _snapshot.value.buffered).abs() <
          const Duration(seconds: 1)) {
        return;
      }
      _set(buffered: value);
    }));
    // Decoded size decides the fit: a landscape video fills the pane, a
    // portrait one keeps its whole frame.
    _subscriptions.add(_player.stream.width.listen((value) {
      if (value != null && value > 0) {
        _videoSize.value = Size(value.toDouble(), _videoSize.value.height);
      }
    }));
    _subscriptions.add(_player.stream.height.listen((value) {
      if (value != null && value > 0) {
        _videoSize.value = Size(_videoSize.value.width, value.toDouble());
      }
    }));
    // No loop: the player page advances to the next episode on completion.
    _player.setPlaylistMode(PlaylistMode.none);
    _subscriptions.addAll([
      _player.stream.completed.listen((value) {
        if (value) _set(completed: true, playing: false);
      }),
      _player.stream.playing.listen((value) {
        if (value) {
          _pausedByUser = false;
          _set(playing: true);
        } else if (_pausedByUser) {
          _set(playing: false);
        }
      }),
      _player.stream.position.listen(_onPosition),
      // A growing remux stream reports duration 0 even while it plays. Keep
      // the source-declared duration in that case; a real value always wins.
      _player.stream.duration.listen((value) {
        if (value > Duration.zero || _planDuration <= Duration.zero) {
          _set(duration: value);
        }
      }),
      _player.stream.rate.listen((value) {
        if ((value - _desiredRate).abs() > 0.001) {
          // libmpv resets `speed` when a new media loads, which made the next
          // episode start at 1.0x. Restore the user's choice instead.
          unawaited(_player.setRate(_desiredRate));
          return;
        }
        _set(rate: value);
      }),
      _player.stream.volume.listen((value) => _set(volume: value / 100)),
      _player.stream.error.listen(_onError),
    ]);
  }

  /// media_kit turns mpv's `[ad]`/`[vd]` log lines into stream errors. An
  /// audio track it cannot decode does not stop the picture, so treating it as
  /// fatal replaced a playing video with the error panel ("ERROR decoding
  /// audio" was one of these). Video and connection failures still surface.
  void _onError(String message) {
    final text = message.toLowerCase();
    final seekOnly = text.contains('seek') &&
        (text.contains('force-seekable') || text.contains('cannot seek'));
    if (seekOnly) {
      // Seeking a stream that is still being written can fail for one command
      // without stopping playback. The next build enables force-seekable; do
      // not replace a playing picture with the fatal error panel meanwhile.
      AppLog.write('player seek: $message');
      return;
    }
    final audioOnly = (text.contains('audio') ||
            text.contains('wasapi') ||
            text.contains('ao/')) &&
        !text.contains('video');
    if (audioOnly) {
      // A broken audio track reports once per packet; writing every line
      // turned one decode failure into megabytes of log and disk churn.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastAudioLogMs > 5000) {
        _lastAudioLogMs = now;
        AppLog.write('player audio: $message');
      }
      return;
    }
    _set(error: message);
  }

  /// Cache profile of the engine that is playing: a minute of read-ahead so
  /// dragging stays instant, bounded in bytes so three engines cannot eat the
  /// machine.
  static const Map<String, String> _playingProfile = {
    'demuxer-readahead-secs': '60',
    'cache-secs': '60',
    'cache-pause': 'no',
    'network-timeout': '20',
    // The core may still be growing a remuxed/transcoded file when the player
    // opens it; without this, seeking in that stream is rejected.
    'force-seekable': 'yes',
    'demuxer-max-bytes': '32MiB',
    'demuxer-max-back-bytes': '8MiB',
    // Read the next playlist entry before the current one ends. The episode
    // switch then loads a file that is already in the demuxer cache instead of
    // tearing down the pipeline and showing a black frame.
    'prefetch-playlist': 'yes',
    // libavcodec scales its thread count with the core count, and for a VVC
    // stream that meant ~7 cores of decoding for a picture that needs one:
    // a 1080p episode decodes at 6x realtime on a single thread. Two leaves
    // headroom for slower machines without pinning the machine.
    'vd-lavc-threads': '2',
  };

  /// Applied once per engine instance: these mpv properties survive media
  /// changes, so reapplying them on every open/play only added FFI round
  /// trips to the switch path.
  Future<void> _tune() => _applyProfile(_playingProfile);

  /// The decoder mpv actually opened for the current stream ("no" means a
  /// software decode). Used to decide whether bytevc2 needs converting.
  Future<String> hardwareDecoder() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return '';
    try {
      return (await platform.getProperty('hwdec-current')).toLowerCase();
    } on Object {
      return '';
    }
  }

  Future<void> _applyProfile(Map<String, String> profile) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final entry in profile.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } on Object catch (e) {
        AppLog.write('mpv: cannot set ${entry.key}=${entry.value}: $e');
        // Older libmpv builds may not know one property; keep tuning the
        // rest instead of leaving every later option at its default.
      }
    }
  }

  late final Future<void> _tuned;

  final BoxFit fit;
  final Player _player;
  late final VideoController _controller;
  final ValueNotifier<Size> _videoSize = ValueNotifier(Size.zero);
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final ValueNotifier<PlaybackSnapshot> _snapshot =
      ValueNotifier(const PlaybackSnapshot());
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  // mpv reports `time-pos` far more often than a 60 fps progress bar needs.
  // The playhead updates at ~16 Hz, while the coarse snapshot (play/pause,
  // volume, buffering, errors) only needs a few updates per second.
  static const int _positionUiMs = 60;
  // The coarse snapshot only needs the playhead for low-frequency fallbacks
  // (cover curtain, danmaku windows); the seek bar and danmaku listen to
  // [position] instead.
  static const int _positionSnapshotMs = 1000;
  int _lastUiPositionMs = 0;
  int _lastSnapshotPositionMs = 0;
  int _lastAudioLogMs = 0;
  // media_kit reports `playing: false` while buffering or between loop
  // restarts. Track the intent so the UI does not flash a pause badge during
  // playback.
  bool _pausedByUser = false;
  // The rate the user asked for; libmpv drops it on every media load.
  double _desiredRate = 1.0;
  double _desiredVolume = 1.0;
  // The item appended behind the current one. libmpv prefetches it; switching
  // with playlist-pos keeps the same video output and decoder pipeline.
  String _queuedEpisodeId = '';
  String _queuedUrl = '';
  // Source URLs are signed and expire after a few minutes. Jumping into a
  // playlist entry queued long ago makes libmpv fail decoder setup on the
  // expired stream ("Failed to initialize a decoder for codec ''"); past this
  // age the caller is told to fetch a fresh plan instead.
  DateTime? _queuedAt;
  static const Duration _queuedTtl = Duration(seconds: 90);
  // Duration the source declared for the current/queued episode. libmpv
  // cannot always derive one from a stream that is still being written.
  Duration _planDuration = Duration.zero;
  Duration _queuedDuration = Duration.zero;

  @override
  ValueListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<Duration> get position => _position;

  void _onPosition(Duration value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUiPositionMs >= _positionUiMs) {
      _lastUiPositionMs = now;
      if (_position.value != value) _position.value = value;
    }
    if (now - _lastSnapshotPositionMs >= _positionSnapshotMs) {
      _lastSnapshotPositionMs = now;
      _set(position: value);
    }
  }

  void _set({
    bool? ready,
    bool? playing,
    Duration? position,
    Duration? duration,
    double? rate,
    double? volume,
    String? error,
    bool? completed,
    bool? buffering,
    Duration? buffered,
  }) {
    final current = _snapshot.value;
    _snapshot.value = PlaybackSnapshot(
      ready: ready ?? current.ready,
      playing: playing ?? current.playing,
      position: position ?? current.position,
      duration: duration ?? current.duration,
      rate: rate ?? current.rate,
      volume: volume ?? current.volume,
      error: error ?? current.error,
      completed: completed ?? current.completed,
      buffering: buffering ?? current.buffering,
      buffered: buffered ?? current.buffered,
    );
  }

  Future<Media?> _mediaOf(MediaPlan plan) async {
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) return null;
    // Client-side protection: the API sends ciphertext plus the key, and a
    // loopback proxy decrypts each requested range.
    var url = stream.url;
    final decryption = stream.decryption ?? plan.decryption;
    if (decryption.required &&
        decryption.location == 'client' &&
        decryption.keyHex.isNotEmpty) {
      url = await DecryptProxy.instance.register(url, decryption.keyHex);
    }
    // Direct CDN opens carry the same UA/identity headers as the decrypting
    // proxy.
    final headers = url.startsWith('http')
        ? DecryptProxy.mediaHeaders(Uri.parse(url))
        : null;
    return Media(url, httpHeaders: headers);
  }

  /// [autoPlay] false loads the file and decodes the first frame without
  /// starting playback, so a second engine can preload the next card.
  @override
  Future<void> open(MediaPlan plan, {bool autoPlay = true}) async {
    // Reset before anything awaits: the outgoing media keeps reporting its
    // position while profiles are applied and the coordinator claims, and the
    // page uses `ready` + position to decide that the new episode started.
    _planDuration = plan.duration;
    _queuedDuration = Duration.zero;
    _snapshot.value = PlaybackSnapshot(
      rate: _desiredRate,
      volume: _desiredVolume,
      duration: _planDuration,
    );
    _position.value = Duration.zero;
    _videoSize.value = Size.zero;
    _lastUiPositionMs = 0;
    _lastSnapshotPositionMs = 0;
    _queuedEpisodeId = '';
    _queuedUrl = '';
    _queuedAt = null;
    await _tuned;
    await _applyCodecProfile(plan);
    // Claim before the stream check: a new player with no stream must still
    // stop whatever was playing behind it.
    if (autoPlay) await PlaybackCoordinator.instance.claim(this);
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) {
      _snapshot.value = const PlaybackSnapshot(error: '没有可播放的视频流');
      return;
    }
    _pausedByUser = false;
    try {
      final media = await _mediaOf(plan);
      if (media == null) {
        _snapshot.value = const PlaybackSnapshot(error: '没有可播放的视频流');
        return;
      }
      // Same Player and texture: the next episode is another file opened in
      // the existing pipeline, not a reload of the player.
      await _player.open(media, play: autoPlay);
      if ((_desiredRate - 1.0).abs() > 0.001) {
        await _player.setRate(_desiredRate);
      }
      await _player.setVolume((_desiredVolume * 100).clamp(0, 100));
      final reported = _snapshot.value.duration;
      _snapshot.value = PlaybackSnapshot(
        ready: true,
        playing: autoPlay,
        rate: _desiredRate,
        volume: _desiredVolume,
        duration: reported > Duration.zero ? reported : _planDuration,
      );
    } on Object catch (error) {
      _snapshot.value = PlaybackSnapshot(error: error.toString());
    }
  }

  @override
  Future<void> queueNext(MediaPlan plan) async {
    final episodeId = plan.episodeId;
    if (episodeId.isEmpty || episodeId == _queuedEpisodeId) return;
    await _tuned;
    try {
      final media = await _mediaOf(plan);
      if (media == null) return;
      // Replace a stale queued entry: the playlist may still hold the item
      // from a previous quality or episode choice.
      if (_queuedEpisodeId.isNotEmpty) {
        final old = _player.state.playlist.medias.indexWhere(
          (item) => item.uri == _queuedUrl,
        );
        if (old > _player.state.playlist.index) {
          try {
            await _player.remove(old);
          } on Object {
            // The entry may already have been consumed.
          }
        }
      }
      await _player.add(media);
      _queuedEpisodeId = episodeId;
      _queuedUrl = media.uri;
      _queuedAt = DateTime.now();
      _queuedDuration = plan.duration;
      AppLog.write('player queued next: $episodeId');
    } on Object catch (error) {
      AppLog.write('player queue next: $error');
    }
  }

  @override
  Future<bool> playQueuedNext(String episodeId) async {
    if (episodeId.isEmpty || episodeId != _queuedEpisodeId) return false;
    final queuedAt = _queuedAt;
    if (queuedAt != null &&
        DateTime.now().difference(queuedAt) > _queuedTtl) {
      AppLog.write('player queue stale: $episodeId');
      // Forget the stale identity so the caller's fresh queueNext() can add
      // a new playlist entry instead of being skipped as a duplicate.
      _queuedEpisodeId = '';
      _queuedUrl = '';
      _queuedAt = null;
      _queuedDuration = Duration.zero;
      return false;
    }
    final index = _player.state.playlist.medias.indexWhere(
      (item) => item.uri == _queuedUrl,
    );
    if (index < 0) return false;
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    try {
      // Do not use Player.next(): media_kit's implementation calls play(),
      // which treats the just-finished media as "completed" and seeks it back
      // to zero before advancing. Set the playlist position directly, so the
      // prefetched entry starts without re-opening the current one.
      _pausedByUser = false;
      _planDuration = _queuedDuration;
      _position.value = Duration.zero;
      _snapshot.value = PlaybackSnapshot(
        ready: true,
        rate: _desiredRate,
        volume: _desiredVolume,
        duration: _planDuration,
        playing: true,
      );
      await platform.setProperty('pause', 'no');
      await platform.setProperty('playlist-pos', '$index');
      AppLog.write('player playlist next: $episodeId -> $index');
      _queuedEpisodeId = '';
      _queuedUrl = '';
      _queuedAt = null;
      _queuedDuration = Duration.zero;
      return true;
    } on Object catch (error) {
      AppLog.write('player play queued: $error');
      return false;
    }
  }

  @override
  Future<void> play() async {
    _pausedByUser = false;
    await PlaybackCoordinator.instance.claim(this);
    await _player.play();
    _set(playing: true, completed: false);
  }

  /// VVC software decode is only the fallback when the gateway cannot hand
  /// back an H.264 copy. Give libavcodec four threads there instead of the
  /// quiet two used for H.264/HEVC; hardware decoding is already requested by
  /// the controller (`hwdec=auto-safe`).
  Future<void> _applyCodecProfile(MediaPlan plan) async {
    final codec = (plan.bestStream?.codec ?? '').toLowerCase();
    final vvc = codec == 'bytevc2' || codec == 'bvc2' || codec == 'vvc';
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    // VVC software decode is the fallback when the gateway cannot hand back
    // an H.264 copy. Use up to four threads, but leave at least two cores for
    // the UI, the gateway and the background transcode.
    final threads = vvc
        ? math.max(2, math.min(4, Platform.numberOfProcessors - 2))
        : 2;
    try {
      await platform.setProperty('vd-lavc-threads', '$threads');
    } on Object catch (error) {
      AppLog.write('mpv: cannot set vd-lavc-threads: $error');
    }
  }

  /// Drops the media of the engine so its buffers are released while the
  /// player itself stays alive for the next open.
  @override
  Future<void> release() async {
    _queuedEpisodeId = '';
    _queuedUrl = '';
    _queuedAt = null;
    _planDuration = Duration.zero;
    _queuedDuration = Duration.zero;
    try {
      await _player.stop();
    } on Object {
      // Already closed.
    }
    _position.value = Duration.zero;
    _set(
      ready: false,
      playing: false,
      position: Duration.zero,
      duration: Duration.zero,
      completed: false,
    );
  }

  Future<void> _pauseForCoordinator() async {
    _pausedByUser = true;
    await _player.pause();
    _set(playing: false);
  }

  @override
  Future<void> pause() async {
    _pausedByUser = true;
    await _player.pause();
    _set(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    // Paint the thumb immediately instead of waiting for mpv's next event.
    _position.value = position;
    _set(position: position);
    await _player.seek(position);
  }

  @override
  Future<void> setRate(double rate) async {
    _desiredRate = rate;
    await _player.setRate(rate);
    _set(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _desiredVolume = volume.clamp(0.0, 1.0);
    await _player.setVolume((_desiredVolume * 100).clamp(0, 100));
    _set(volume: _desiredVolume);
  }

  @override
  Future<void> dispose() async {
    PlaybackCoordinator.instance.unregister(this);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _videoSize.dispose();
    _position.dispose();
    await _player.dispose();
    _snapshot.dispose();
  }

  /// A landscape pane fills with a landscape video (a 16:9 video in a 1.5–1.9
  /// window crops a small strip, which beats top/bottom bars) and letterboxes
  /// a vertical one. A portrait pane (a phone) does the opposite: a vertical
  /// drama fills, while a landscape film keeps its whole frame instead of
  /// losing most of its width to the short screen.
  BoxFit _fitFor(Size video, Size view) {
    if (video.width <= 0 ||
        video.height <= 0 ||
        view.width <= 0 ||
        view.height <= 0) {
      return fit;
    }
    final videoLandscape = video.width / video.height >= 1.2;
    final viewLandscape = view.width > view.height;
    if (viewLandscape) {
      return videoLandscape ? BoxFit.cover : BoxFit.contain;
    }
    return videoLandscape ? BoxFit.contain : BoxFit.cover;
  }

  @override
  Widget buildSurface(BuildContext context) {
    return ValueListenableBuilder<Size>(
      valueListenable: _videoSize,
      builder: (context, videoSize, _) => LayoutBuilder(
        builder: (context, constraints) => Video(
          // A new key per controller: media_kit's Video keeps its texture
          // attachments in state, and switching the page to a preloaded
          // engine used to leave the old (released) texture on screen — sound
          // from the new player, no picture.
          key: ObjectKey(_controller),
          controller: _controller,
          controls: NoVideoControls,
          fit: _fitFor(
            videoSize,
            Size(constraints.maxWidth, constraints.maxHeight),
          ),
          fill: Colors.black,
        ),
      ),
    );
  }
}
