import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../sp/models.dart';
import 'bvc2_playback_engine.dart';
import 'media_kit_playback_engine.dart';
import 'playback_engine.dart';

/// One engine for the whole process that routes VVC plans to the Android
/// ByteVC2 player and everything else to media_kit. The rest of the player
/// keeps a single stable snapshot/position pair.
class HybridPlaybackEngine implements PlaybackEngine {
  HybridPlaybackEngine({BoxFit fit = BoxFit.contain}) : _fit = fit;

  final BoxFit _fit;
  MediaKitPlaybackEngine? _mediaKit;
  Bvc2PlaybackEngine? _bvc2;
  PlaybackEngine? _active;
  bool _activeIsBvc2 = false;

  final ValueNotifier<PlaybackSnapshot> _snapshot =
      ValueNotifier(const PlaybackSnapshot());
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);

  @override
  ValueListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<Duration> get position => _position;

  static bool _isVvc(String? codec) {
    switch ((codec ?? '').toLowerCase()) {
      case 'bytevc2':
      case 'bvc2':
      case 'vvc':
        return true;
    }
    return false;
  }

  void _bind(PlaybackEngine engine, {required bool bvc2}) {
    if (identical(engine, _active)) {
      _activeIsBvc2 = bvc2;
      return;
    }
    _detach();
    _active = engine;
    _activeIsBvc2 = bvc2;
    engine.snapshot.addListener(_mirrorSnapshot);
    engine.position.addListener(_mirrorPosition);
    _mirrorSnapshot();
    _mirrorPosition();
  }

  void _detach() {
    final active = _active;
    if (active == null) return;
    active.snapshot.removeListener(_mirrorSnapshot);
    active.position.removeListener(_mirrorPosition);
    _active = null;
  }

  void _mirrorSnapshot() {
    final value = _active?.snapshot.value;
    if (value != null) _snapshot.value = value;
  }

  void _mirrorPosition() {
    final value = _active?.position.value;
    if (value != null) _position.value = value;
  }

  @override
  Future<void> open(MediaPlan plan, {bool autoPlay = true}) async {
    // An empty plan is handled by the delegate so the page still gets the
    // standard "no playable stream" state.
    final codec = plan.bestStream?.codec;
    final useBvc2 = _isVvc(codec) && await Bvc2PlaybackEngine.isAvailable();
    if (useBvc2) {
      final engine = _bvc2 ??= Bvc2PlaybackEngine(fit: _fit);
      unawaited(_mediaKit?.release());
      _bind(engine, bvc2: true);
      await engine.open(plan, autoPlay: autoPlay);
      return;
    }
    final engine = _mediaKit ??= MediaKitPlaybackEngine(fit: _fit);
    unawaited(_bvc2?.release());
    _bind(engine, bvc2: false);
    await engine.open(plan, autoPlay: autoPlay);
  }

  @override
  Future<void> queueNext(MediaPlan plan) async {
    if (_activeIsBvc2 || _isVvc(plan.bestStream?.codec)) return;
    await _mediaKit?.queueNext(plan);
  }

  @override
  Future<bool> playQueuedNext(String episodeId) async {
    if (_activeIsBvc2) return false;
    return await _mediaKit?.playQueuedNext(episodeId) ?? false;
  }

  @override
  Future<String> hardwareDecoder() async =>
      await _active?.hardwareDecoder() ?? '';

  @override
  Future<void> play() async {
    await _active?.play();
  }

  @override
  Future<void> pause() async {
    await _active?.pause();
  }

  @override
  Future<void> release() async {
    await _active?.release();
  }

  @override
  Future<void> seek(Duration position) async {
    await _active?.seek(position);
  }

  @override
  Future<void> setRate(double rate) async {
    await _active?.setRate(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _active?.setVolume(volume);
  }

  @override
  Future<void> dispose() async {
    _detach();
    await _mediaKit?.dispose();
    await _bvc2?.dispose();
    _snapshot.dispose();
    _position.dispose();
  }

  @override
  Widget buildSurface(BuildContext context) =>
      _active?.buildSurface(context) ??
      const ColoredBox(color: Color(0xFF000000));
}
