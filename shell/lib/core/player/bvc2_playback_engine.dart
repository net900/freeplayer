import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../decryptor/decrypt_proxy.dart';
import '../logging/app_log.dart';
import '../sp/models.dart';
import 'playback_engine.dart';

/// ByteVC2 (VVC) playback through Media3 and the vendor software decoder.
/// Only used on Android where [isAvailable] reports true; every other plan
/// stays on media_kit.
class Bvc2PlaybackEngine implements PlaybackEngine {
  Bvc2PlaybackEngine({this.fit = BoxFit.contain});

  static const MethodChannel _channel = MethodChannel('free_player/bvc2');
  static const EventChannel _events =
      EventChannel('free_player/bvc2/events');

  static bool? _available;

  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    final cached = _available;
    if (cached != null) return cached;
    try {
      final value = await _channel.invokeMethod<bool>('isAvailable') ?? false;
      _available = value;
      return value;
    } on MissingPluginException {
      _available = false;
      return false;
    } on PlatformException {
      _available = false;
      return false;
    }
  }

  final BoxFit fit;
  final ValueNotifier<PlaybackSnapshot> _snapshot =
      ValueNotifier(const PlaybackSnapshot());
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  // Flutter's first texture id is 0, so -1 means "no texture yet".
  final ValueNotifier<int> _textureId = ValueNotifier(-1);
  final ValueNotifier<Size> _videoSize = ValueNotifier(Size.zero);
  StreamSubscription<dynamic>? _eventsSub;
  double _volume = 1.0;
  double _rate = 1.0;

  @override
  ValueListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<Duration> get position => _position;

  void _listen() {
    _eventsSub ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        AppLog.write('bvc2 events: $error');
      },
    );
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final textureId = (raw['textureId'] as num?)?.toInt() ?? -1;
    if (textureId >= 0 && _textureId.value != textureId) {
      _textureId.value = textureId;
    }
    final width = (raw['width'] as num?)?.toInt() ?? 0;
    final height = (raw['height'] as num?)?.toInt() ?? 0;
    if (width > 0 && height > 0) {
      final size = Size(width.toDouble(), height.toDouble());
      if (_videoSize.value != size) _videoSize.value = size;
    }
    final positionMs = (raw['positionMs'] as num?)?.toInt() ?? 0;
    final bufferedMs = (raw['bufferedMs'] as num?)?.toInt() ?? 0;
    final durationMs = (raw['durationMs'] as num?)?.toInt() ?? 0;
    final playing = raw['playing'] == true;
    final buffering = raw['buffering'] == true;
    final ready = raw['ready'] == true;
    final completed = raw['completed'] == true;
    final error = raw['error'] as String?;
    final current = _snapshot.value;
    final nextDuration =
        durationMs > 0 ? Duration(milliseconds: durationMs) : current.duration;
    final nextPosition = Duration(milliseconds: positionMs);
    if (_position.value != nextPosition) _position.value = nextPosition;
    final next = PlaybackSnapshot(
      ready: ready,
      playing: playing,
      position: nextPosition,
      duration: nextDuration,
      rate: _rate,
      volume: _volume,
      error: error == null || error.isEmpty ? null : error,
      completed: completed,
      buffering: buffering,
      buffered: Duration(milliseconds: bufferedMs),
    );
    if (next.ready != current.ready ||
        next.playing != current.playing ||
        next.duration != current.duration ||
        next.error != current.error ||
        next.completed != current.completed ||
        next.buffering != current.buffering ||
        next.buffered != current.buffered ||
        next.position != current.position) {
      _snapshot.value = next;
    }
  }

  /// Whether a plan belongs to the VVC engine on this platform.
  static bool isVvcCodec(String? codec) {
    switch ((codec ?? '').toLowerCase()) {
      case 'bytevc2':
      case 'bvc2':
      case 'vvc':
        return true;
    }
    return false;
  }

  static bool handlesPlan(MediaPlan plan) =>
      Platform.isAndroid && isVvcCodec(plan.bestStream?.codec);

  /// Prefetch hook: parses the CENC index off the UI path. The Kotlin side
  /// fetches the moov window and decrypts in-process, so opening the episode
  /// does not repeat those CDN round trips during a switch.
  static void warm(MediaPlan plan) {
    if (!Platform.isAndroid) return;
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty || !isVvcCodec(stream.codec)) {
      return;
    }
    final decryption = stream.decryption ?? plan.decryption;
    if (!decryption.required ||
        decryption.location != 'client' ||
        decryption.keyHex.isEmpty) {
      return;
    }
    unawaited(_invokeWarm(stream.url, decryption.keyHex));
  }

  static Future<void> _invokeWarm(String url, String keyHex) async {
    try {
      await _channel.invokeMethod<void>('warm', {
        'url': url,
        'keyHex': keyHex,
        'userAgent': DecryptProxy.videoUserAgent,
      });
    } on Object {
      // Opening the episode retries on demand.
    }
  }

  @override
  Future<void> open(MediaPlan plan, {bool autoPlay = true}) async {
    final stream = plan.bestStream;
    if (stream == null || stream.url.isEmpty) {
      _snapshot.value = const PlaybackSnapshot(error: '没有可播放的视频流');
      return;
    }
    final decryption = stream.decryption ?? plan.decryption;
    // The key goes straight to the Kotlin DataSource; there is no loopback
    // proxy on this path any more.
    final keyHex = decryption.required &&
            decryption.location == 'client' &&
            decryption.keyHex.isNotEmpty
        ? decryption.keyHex
        : '';
    _listen();
    _textureId.value = -1;
    _videoSize.value = Size.zero;
    _position.value = Duration.zero;
    _snapshot.value = PlaybackSnapshot(
      duration: plan.duration,
      playing: autoPlay,
      rate: _rate,
      volume: _volume,
    );
    try {
      final texture = await _channel.invokeMethod<int>('open', {
        'url': stream.url,
        'autoPlay': autoPlay,
        'startMs': 0,
        'keyHex': keyHex,
        'userAgent': DecryptProxy.videoUserAgent,
      });
      if (texture != null && texture >= 0) _textureId.value = texture;
      _snapshot.value = _snapshot.value.copyWith(ready: true);
    } on Object catch (error) {
      AppLog.write('bvc2 open: $error');
      _snapshot.value = PlaybackSnapshot(error: error.toString());
    }
  }

  @override
  Future<void> queueNext(MediaPlan plan) async {}

  @override
  Future<bool> playQueuedNext(String episodeId) async => false;

  @override
  Future<String> hardwareDecoder() async => 'bytevc2';

  @override
  Future<void> play() async {
    await _channel.invokeMethod<void>('play');
    _snapshot.value = _snapshot.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    await _channel.invokeMethod<void>('pause');
    _snapshot.value = _snapshot.value.copyWith(playing: false);
  }

  @override
  Future<void> release() async {
    await _channel.invokeMethod<void>('release');
    _position.value = Duration.zero;
    _snapshot.value = const PlaybackSnapshot();
  }

  @override
  Future<void> seek(Duration position) async {
    _position.value = position;
    _snapshot.value = _snapshot.value.copyWith(position: position);
    await _channel.invokeMethod<void>('seek', {
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    _snapshot.value = _snapshot.value.copyWith(rate: rate);
    await _channel.invokeMethod<void>('rate', {'rate': rate});
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _snapshot.value = _snapshot.value.copyWith(volume: _volume);
    await _channel.invokeMethod<void>('volume', {'volume': _volume});
  }

  @override
  Future<void> dispose() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    try {
      await _channel.invokeMethod<void>('dispose');
    } on Object {
      // The activity may already be gone.
    }
    _snapshot.dispose();
    _position.dispose();
    _textureId.dispose();
    _videoSize.dispose();
  }

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
    return ValueListenableBuilder<int>(
      valueListenable: _textureId,
      builder: (context, id, _) {
        if (id < 0) return const ColoredBox(color: Colors.black);
        return ValueListenableBuilder<Size>(
          valueListenable: _videoSize,
          builder: (context, size, _) {
            final video =
                size.width > 0 && size.height > 0 ? size : const Size(16, 9);
            return LayoutBuilder(
              builder: (context, constraints) {
                final fit = _fitFor(
                  video,
                  Size(constraints.maxWidth, constraints.maxHeight),
                );
                return ClipRect(
                  child: FittedBox(
                    fit: fit,
                    child: SizedBox(
                      width: video.width,
                      height: video.height,
                      child: Texture(
                        textureId: id,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}
