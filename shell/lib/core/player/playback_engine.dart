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
    );
  }
}

/// The swappable playback contract (PRD §5.5, §8.3). A media_kit or
/// video_player_win adapter implements this without touching the UI.
abstract class PlaybackEngine {
  ValueListenable<PlaybackSnapshot> get snapshot;

  /// Loads [plan]; [autoPlay] false decodes the first frame but stays paused,
  /// which lets a second engine preload the next item.
  Future<void> open(MediaPlan plan, {bool autoPlay = true});

  Future<void> play();

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
