import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../sp/models.dart';

@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.ready = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1.0,
    this.volume = 1.0,
    this.error,
    this.completed = false,
    this.buffering = false,
    this.buffered = Duration.zero,
  });

  final bool ready;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double rate;
  final double volume;
  final String? error;
  final bool completed;
  final bool buffering;

  /// How far the decoder has buffered ahead of the playhead. Zero when the
  /// engine cannot report it.
  final Duration buffered;

  PlaybackSnapshot copyWith({
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
    return PlaybackSnapshot(
      ready: ready ?? this.ready,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      rate: rate ?? this.rate,
      volume: volume ?? this.volume,
      error: error ?? this.error,
      completed: completed ?? this.completed,
      buffering: buffering ?? this.buffering,
      buffered: buffered ?? this.buffered,
    );
  }
}

/// The swappable playback contract (PRD §5.5, §8.3). A media_kit or
/// video_player_win adapter implements this without touching the UI.
abstract class PlaybackEngine {
  ValueListenable<PlaybackSnapshot> get snapshot;

  /// High-frequency playhead for the progress bar and danmaku. Kept separate
  /// from [snapshot] so a 60–250 ms position tick does not rebuild every
  /// widget that only cares about play/pause, volume or errors.
  ValueListenable<Duration> get position;

  /// Loads [plan]; [autoPlay] false decodes the first frame but stays paused,
  /// which lets a second engine preload the next item.
  Future<void> open(MediaPlan plan, {bool autoPlay = true});

  /// Appends the next item to the player's own playlist without touching the
  /// picture that is playing. libmpv can prefetch that entry, so the eventual
  /// switch does not rebuild the video output.
  Future<void> queueNext(MediaPlan plan) async {}

  /// Switches to the queued episode when [episodeId] is the one queued.
  /// Returns false when the caller must open normally.
  Future<bool> playQueuedNext(String episodeId) async => false;

  Future<void> play();

  /// The decoder the engine opened for the current stream; "no" means a
  /// software decode. Engines without a hardware path answer an empty string.
  Future<String> hardwareDecoder() async => '';

  Future<void> pause();

  /// Drops the loaded media of an idle engine, releasing its buffers.
  Future<void> release();

  Future<void> seek(Duration position);

  Future<void> setRate(double rate);

  Future<void> setVolume(double volume);

  Future<void> dispose();

  /// The engine-owned video surface. Stub engines return a plain box so the
  /// surrounding UI does not need to know which kernel is active.
  Widget buildSurface(BuildContext context);
}
