import 'dart:async';

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
  MediaKitPlaybackEngine({this.fit = BoxFit.cover}) : _player = Player() {
    // `hwdec=auto` may pick a decoder that decodes audio but never produces a
    // picture; auto-safe only uses hardware paths known to render correctly
    // and falls back to software otherwise.
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(hwdec: 'auto-safe'),
    );
    _tuned = _tune();
    PlaybackCoordinator.instance.register(this, _pauseForCoordinator);
    _subscriptions.add(_player.stream.buffering.listen((value) {
      _set(buffering: value);
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
      _player.stream.position.listen((value) => _set(position: value)),
      _player.stream.duration.listen((value) => _set(duration: value)),
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
    final audioOnly = (text.contains('audio') ||
            text.contains('wasapi') ||
            text.contains('ao/')) &&
        !text.contains('video');
    if (audioOnly) {
      AppLog.write('player audio: $message');
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
    'demuxer-max-bytes': '64MiB',
    'demuxer-max-back-bytes': '16MiB',
  };

  /// Cache profile while a spare engine only preloads the next item: enough
  /// to show its first frame, not enough to download a whole episode in the
  /// background.
  static const Map<String, String> _preloadProfile = {
    'demuxer-readahead-secs': '8',
    'cache-secs': '8',
    'cache-pause': 'no',
    'network-timeout': '20',
    'demuxer-max-bytes': '16MiB',
    'demuxer-max-back-bytes': '0',
  };

  Future<void> _tune() => _applyProfile(_playingProfile);

  Future<void> _applyProfile(Map<String, String> profile) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final entry in profile.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } on Object {
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
  // media_kit reports `playing: false` while buffering or between loop
  // restarts. Track the intent so the UI does not flash a pause badge during
  // playback.
  bool _pausedByUser = false;
  // The rate the user asked for; libmpv drops it on every media load.
  double _desiredRate = 1.0;
  double _desiredVolume = 1.0;

  @override
  ValueListenable<PlaybackSnapshot> get snapshot => _snapshot;

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
    );
  }

  /// [autoPlay] false loads the file and decodes the first frame without
  /// starting playback, so a second engine can preload the next card.
  @override
  Future<void> open(MediaPlan plan, {bool autoPlay = true}) async {
    // Reset before anything awaits: the outgoing media keeps reporting its
    // position while profiles are applied and the coordinator claims, and the
    // page uses `ready` + position to decide that the new episode started.
    _snapshot.value = PlaybackSnapshot(
      rate: _desiredRate,
      volume: _desiredVolume,
    );
    _videoSize.value = Size.zero;
    await _tuned;
    // A paused engine only preloads: keep its buffers small until it is the
    // one actually playing. Promotion happens in [play].
    await _applyProfile(autoPlay ? _playingProfile : _preloadProfile);
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
      // Client-side protection: the API sends ciphertext plus the key, and a
      // loopback proxy decrypts each requested range.
      var url = stream.url;
      final decryption = stream.decryption ?? plan.decryption;
      if (decryption.required &&
          decryption.location == 'client' &&
          decryption.keyHex.isNotEmpty) {
        url = await DecryptProxy.instance.register(url, decryption.keyHex);
      }
      // Same Player and texture: the next episode is another file opened in
      // the existing pipeline, not a reload of the player.
      await _player.open(Media(url), play: autoPlay);
      if ((_desiredRate - 1.0).abs() > 0.001) {
        await _player.setRate(_desiredRate);
      }
      await _player.setVolume((_desiredVolume * 100).clamp(0, 100));
      _snapshot.value = PlaybackSnapshot(
        ready: true,
        playing: autoPlay,
        rate: _desiredRate,
        volume: _desiredVolume,
      );
    } on Object catch (error) {
      _snapshot.value = PlaybackSnapshot(error: error.toString());
    }
  }

  @override
  Future<void> play() async {
    _pausedByUser = false;
    await PlaybackCoordinator.instance.claim(this);
    // This engine may have been preloading with small buffers; give it the
    // full cache now that it is the one on screen.
    await _applyProfile(_playingProfile);
    await _player.play();
    _set(playing: true, completed: false);
  }

  /// Drops the media of an idle engine so its buffers are released.
  @override
  Future<void> release() async {
    try {
      await _player.stop();
    } on Object {
      // Already closed.
    }
    _set(playing: false, position: Duration.zero, duration: Duration.zero);
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
  Future<void> seek(Duration position) => _player.seek(position);

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
    await _player.dispose();
    _snapshot.dispose();
  }

  /// Landscape fills the pane (a 16:9 video in a 1.5–1.9 window crops a small
  /// strip, which beats top/bottom bars); portrait keeps its whole frame so
  /// the top and bottom of a vertical drama are not cut off.
  BoxFit _fitFor(Size video, Size view) {
    if (video.width <= 0 ||
        video.height <= 0 ||
        view.width <= 0 ||
        view.height <= 0) {
      return fit;
    }
    return video.width / video.height >= 1.2
        ? BoxFit.cover
        : BoxFit.contain;
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
