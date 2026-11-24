import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../sp/models.dart';
import 'playback_engine.dart';

/// Placeholder until a real kernel is integrated. It reports why nothing is
/// playing instead of pretending to succeed.
class StubPlaybackEngine implements PlaybackEngine {
  final ValueNotifier<PlaybackSnapshot> _snapshot =
      ValueNotifier(const PlaybackSnapshot());
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);

  @override
  ValueListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<Duration> get position => _position;

  @override
  Future<void> open(MediaPlan plan, {bool autoPlay = true}) async {
    final hasPlayableStream =
        plan.bestStream != null && plan.bestStream!.url.isNotEmpty;
    _snapshot.value = _snapshot.value.copyWith(
      ready: false,
      playing: false,
      duration: Duration(
        seconds: plan.extra['duration_sec'] is int
            ? plan.extra['duration_sec'] as int
            : 0,
      ),
      error:
          hasPlayableStream ? AppStrings.playerNotReady : AppStrings.noStream,
    );
  }

  @override
  Future<void> queueNext(MediaPlan plan) async {}

  @override
  Future<bool> playQueuedNext(String episodeId) async => false;

  @override
  Future<void> play() async {}

  @override
  Future<String> hardwareDecoder() async => '';

  @override
  Future<void> pause() async {}

  @override
  Future<void> release() async {}

  @override
  Future<void> seek(Duration position) async {
    _position.value = position;
  }

  @override
  Future<void> setRate(double rate) async {
    _snapshot.value = _snapshot.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _snapshot.value = _snapshot.value.copyWith(volume: volume);
  }

  @override
  Future<void> dispose() async {
    _position.dispose();
    _snapshot.dispose();
  }

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);
}
