import 'dart:async';

import 'package:flutter/material.dart';

import '../sp/models.dart';
import 'media_kit_playback_engine.dart';
import 'playback_coordinator.dart';
import 'playback_engine.dart';

/// A small ring of engines: one is active, the others hold the next videos
/// paused. Switching to a preloaded item is a claim plus play, not a fresh
/// network open, so the picture appears immediately.
///
/// Engines are created on demand: a page that never preloads owns exactly one
/// libmpv instance instead of three, and a spare engine drops its media as
/// soon as its neighbour is no longer useful.
class PlaybackPool {
  PlaybackPool({this.size = 3, BoxFit fit = BoxFit.contain}) : _fit = fit;

  final int size;
  final BoxFit _fit;
  late final List<PlaybackEngine?> _engines =
      List<PlaybackEngine?>.filled(size, null);
  late final List<String> _keys = List<String>.filled(size, '');
  late final List<DateTime?> _preloadedAt = List<DateTime?>.filled(size, null);
  int _active = 0;

  /// A preload older than this is dropped instead of adopted: its signed
  /// stream URL may already be dead, which is what made a scrolled-to episode
  /// fail while reopening the same episode worked.
  static const Duration _preloadTtl = Duration(seconds: 120);

  /// Called after [adopt] moved the active engine, so pages can re-attach
  /// their snapshot listener to the engine that is now playing.
  ValueChanged<PlaybackEngine>? onActiveChanged;

  PlaybackEngine get active => _ensureEngine(_active);

  PlaybackEngine _ensureEngine(int slot) =>
      _engines[slot] ??= MediaKitPlaybackEngine(fit: _fit);

  /// Opens [plan] in the active engine (a non-preloaded switch).
  Future<void> openActive(String key, MediaPlan plan) async {
    for (var i = 0; i < _keys.length; i++) {
      // The other slots held this position's neighbours; a jump elsewhere
      // makes them stale.
      if (i != _active) _drop(i);
    }
    _keys[_active] = '';
    _preloadedAt[_active] = null;
    await active.open(plan);
    _keys[_active] = key;
  }

  /// Loads [plan] paused into a spare slot, so [adopt] can start it without
  /// waiting for the network.
  Future<void> preload(String key, MediaPlan plan) async {
    if (key.isEmpty) return;
    if (_keys.contains(key)) return;
    var slot = -1;
    for (var i = 0; i < _engines.length; i++) {
      if (i != _active && _keys[i].isEmpty) {
        slot = i;
        break;
      }
    }
    if (slot < 0) return;
    final engine = _ensureEngine(slot);
    try {
      await engine.open(plan, autoPlay: false);
      _keys[slot] = key;
      _preloadedAt[slot] = DateTime.now();
    } on Object {
      _keys[slot] = '';
      _preloadedAt[slot] = null;
    }
  }

  /// Makes [key] active and starts it. Returns false when it was not
  /// preloaded, so the caller opens it normally.
  Future<bool> adopt(String key) async {
    if (key.isEmpty) return false;
    final index = _keys.indexOf(key);
    if (index < 0) return false;
    final at = _preloadedAt[index];
    if (at == null || DateTime.now().difference(at) > _preloadTtl) {
      _drop(index);
      return false;
    }
    if (index != _active) {
      final previous = _active;
      final next = _ensureEngine(index);
      await PlaybackCoordinator.instance.claim(next);
      await next.play();
      _active = index;
      _preloadedAt[index] = null;
      // The old active is a spare now: drop its media so its buffers do not
      // linger behind the episode that is playing. Wait for the new picture
      // first — releasing it while it was still on screen left a black frame
      // over the new audio.
      _keys[previous] = '';
      unawaited(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_keys[previous].isNotEmpty || previous == _active) return;
        await _engines[previous]?.release();
      }());
      onActiveChanged?.call(next);
    }
    return true;
  }

  /// Drops every preloaded neighbour (tab switch, work switch).
  void forgetPreloads() {
    for (var i = 0; i < _keys.length; i++) {
      if (i != _active) _drop(i);
    }
  }

  void _drop(int slot) {
    _keys[slot] = '';
    _preloadedAt[slot] = null;
    final engine = _engines[slot];
    if (engine == null) return;
    unawaited(engine.release());
  }

  Future<void> pauseActive() => active.pause();

  /// Stops every engine, including the preloaded neighbours. A tab switch
  /// must not leave four streams downloading behind the new page.
  Future<void> pauseAll() async {
    for (final engine in _engines) {
      if (engine == null) continue;
      try {
        await engine.pause();
      } on Object {
        // Best-effort.
      }
    }
  }

  Future<void> dispose() async {
    for (var i = 0; i < _engines.length; i++) {
      final engine = _engines[i];
      if (engine == null) continue;
      _engines[i] = null;
      await engine.dispose();
    }
  }
}
