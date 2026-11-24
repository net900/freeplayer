import 'dart:async';

import 'package:flutter/material.dart';

import '../sp/models.dart';
import 'hybrid_playback_engine.dart';
import 'playback_engine.dart';

/// The app owns exactly one playback engine for the whole process.
///
/// A second engine is not free: a real player creates its own decoder, video
/// output texture and network cache. Preloading therefore only warms plans at
/// the gateway; it never opens a spare player. Switching pages or episodes is
/// an `open()` on the same pipeline.
class PlaybackPool {
  PlaybackPool({int size = 1, BoxFit fit = BoxFit.contain}) : _fit = fit;

  final BoxFit _fit;

  static PlaybackEngine? _shared;

  PlaybackEngine get active => _shared ??= HybridPlaybackEngine(fit: _fit);

  /// Opens [plan] on the single engine. [key] stays in the page contract: the
  /// engine has no per-item slots any more.
  Future<void> openActive(String key, MediaPlan plan) => active.open(plan);

  /// Plans are already warmed by the callers (`/play` prepares the media
  /// index). Opening a spare engine here used to multiply players.
  Future<void> preload(String key, MediaPlan plan) async {}

  /// There is never a preloaded engine to adopt; the caller opens normally.
  Future<bool> adopt(String key) async => false;

  void forgetPreloads() {}

  Future<void> pauseActive() => active.pause();

  Future<void> pauseAll() async {
    final engine = _shared;
    if (engine == null) return;
    try {
      await engine.pause();
    } on Object {
      // Best effort.
    }
  }

  /// A page closed: pause, but keep the single engine and its texture alive
  /// for the next page. Disposing it here would tear down the pipeline the
  /// next page immediately needs again. Media is replaced on the next open,
  /// so no stale stream keeps playing.
  Future<void> dispose() => pauseAll();
}
