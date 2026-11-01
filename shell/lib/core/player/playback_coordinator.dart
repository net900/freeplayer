import 'package:flutter/foundation.dart';

/// Only one playback engine may play at a time. Every engine registers a
/// pause callback; starting playback claims the coordinator and pauses the
/// others. Without this, a feed left mounted behind a pushed player kept
/// decoding sound over the page the user opened.
class PlaybackCoordinator {
  PlaybackCoordinator._();

  static final PlaybackCoordinator instance = PlaybackCoordinator._();

  final Map<Object, Future<void> Function()> _pauses = {};
  Object? _active;

  Object? get active => _active;

  void register(Object owner, Future<void> Function() pause) {
    _pauses[owner] = pause;
  }

  void unregister(Object owner) {
    _pauses.remove(owner);
    if (identical(_active, owner)) _active = null;
  }

  /// Claims playback and pauses every other registered engine.
  Future<void> claim(Object owner) async {
    _active = owner;
    final others = _pauses.entries
        .where((entry) => !identical(entry.key, owner))
        .map((entry) => entry.value)
        .toList(growable: false);
    for (final pause in others) {
      try {
        await pause();
      } on Object catch (error) {
        debugPrint('playback pause failed: $error');
      }
    }
  }

  /// Pauses every engine (used when the app leaves playback entirely).
  Future<void> pauseAll() async {
    _active = null;
    // Engines unregister while being paused (dispose), so iterate a copy.
    for (final pause in _pauses.values.toList(growable: false)) {
      try {
        await pause();
      } on Object catch (error) {
        debugPrint('playback pause failed: $error');
      }
    }
  }
}
