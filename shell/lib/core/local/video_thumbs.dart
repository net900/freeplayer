import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../sp/models.dart';
import '../storage/paths.dart';
import 'local_thumbs.dart';

/// Builds the seek-bar preview strip from the video itself.
///
/// A source only has to return a playable MP4: the client seeks once per tile
/// with ffmpeg and stitches the frames into one JPEG. Seeking is a small Range
/// read, so a remote episode is never downloaded whole; the strip is cached by
/// host+path so re-signed links reuse it.
class VideoThumbs {
  static const int cols = 5;
  static const int rows = 4;
  static const int count = cols * rows;
  static const int tileWidth = 160;
  static const int tileHeight = 90;

  static final Map<String, ThumbStrip> _memory = {};
  static final Set<String> _loading = {};

  /// Stable identity for an episode link: the source re-signs its query on
  /// every fetch, so only host+path identifies the same video.
  static String keyFor(String source) {
    final uri = Uri.tryParse(source);
    final identity = uri == null ? source : '${uri.host}${uri.path}';
    return sha1.convert(utf8.encode(identity)).toString().substring(0, 16);
  }

  static ThumbStrip? cached(String key) => _memory[key];

  /// Returns a ready strip, otherwise builds it in the background and returns
  /// null; [cached] yields the strip once it is ready.
  static Future<ThumbStrip?> load(
    String source, {
    required String cacheKey,
  }) async {
    final known = _memory[cacheKey];
    if (known != null) return known;
    if (!_loading.add(cacheKey)) return null;
    try {
      return await _build(source, cacheKey);
    } finally {
      _loading.remove(cacheKey);
    }
  }

  static bool _pruned = false;

  static Directory get _dir {
    final dir = Directory(joinPath(appDataDirectory().path, 'video_thumbs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Every watched episode leaves a strip behind; keep the folder bounded.
    if (!_pruned) {
      _pruned = true;
      pruneCacheDirectory(dir);
    }
    return dir;
  }

  static Future<ThumbStrip?> _build(String source, String key) async {
    final ffmpeg = LocalThumbs.tool('ffmpeg');
    final ffprobe = LocalThumbs.tool('ffprobe');
    if (ffmpeg == null || ffprobe == null) return null;

    final sprite = File(joinPath(_dir.path, '$key.jpg'));
    final meta = File(joinPath(_dir.path, '$key.json'));
    if (sprite.existsSync() && meta.existsSync()) {
      try {
        final json = Map<String, dynamic>.from(
          jsonDecode(await meta.readAsString()) as Map,
        );
        // v1 used landscape tiles for every video; rebuild those once.
        if (json['version'] != 2) {
          try {
            meta.deleteSync();
          } on Object {}
          try {
            sprite.deleteSync();
          } on Object {}
        } else {
          final strip = ThumbStrip.fromJson(json);
          if (strip.valid && File(strip.url).existsSync()) {
            _memory[key] = strip;
            return strip;
          }
        }
      } on Object {
        // A broken cache entry is simply rebuilt.
      }
    }

    try {
      final duration = await _duration(ffprobe, source);
      if (duration <= 1) return null;
      // Tiles follow the video's orientation: a portrait drama in a 160x90
      // frame was mostly black bars.
      final size = await _size(ffprobe, source);
      final portrait = size != null && size.$2 > size.$1;
      final tileW = portrait ? 90 : tileWidth;
      final tileH = portrait ? 160 : tileHeight;
      // Short clips need sub-second spacing to fill the grid; long ones are
      // capped so a seek never lands past the end.
      final interval = (duration / count).clamp(0.2, 3600.0);
      final tiles = Directory(joinPath(_dir.path, '$key.tiles'));
      if (tiles.existsSync()) tiles.deleteSync(recursive: true);
      tiles.createSync(recursive: true);
      try {
        for (var i = 0; i < count; i++) {
          final at = interval * (i + 0.5);
          final name = 't_${i.toString().padLeft(2, '0')}.jpg';
          final ok = await _run(ffmpeg, [
            '-y',
            '-loglevel',
            'error',
            '-ss',
            at.toStringAsFixed(3),
            '-i',
            source,
            '-frames:v',
            '1',
            '-vf',
            'scale=$tileW:$tileH:'
                'force_original_aspect_ratio=decrease,'
                'pad=$tileW:$tileH:(ow-iw)/2:(oh-ih)/2',
            '-q:v',
            '4',
            joinPath(tiles.path, name),
          ]);
          // A missing tile leaves a hole in the grid; rebuild later instead of
          // showing a strip that lies about the timeline.
          if (ok == null || !File(joinPath(tiles.path, name)).existsSync()) {
            return null;
          }
        }
        final ok = await _run(ffmpeg, [
          '-y',
          '-loglevel',
          'error',
          '-framerate',
          '1',
          '-i',
          joinPath(tiles.path, 't_%02d.jpg'),
          '-vf',
          'tile=${cols}x$rows',
          '-frames:v',
          '1',
          sprite.path,
        ]);
        if (ok == null || !sprite.existsSync() || sprite.lengthSync() == 0) {
          return null;
        }
      } finally {
        try {
          if (tiles.existsSync()) tiles.deleteSync(recursive: true);
        } on Object {
          // Best effort cleanup.
        }
      }

      final strip = ThumbStrip(
        url: sprite.path,
        cols: cols,
        rows: rows,
        count: count,
        tileWidth: tileW,
        tileHeight: tileH,
        intervalSec: interval,
      );
      await meta.writeAsString(jsonEncode({
        'version': 2,
        'url': sprite.path,
        'cols': cols,
        'rows': rows,
        'count': count,
        'tile_width': tileW,
        'tile_height': tileH,
        'interval_sec': interval,
      }));
      _memory[key] = strip;
      return strip;
    } on Object catch (error) {
      debugPrint('video thumbs failed: $error');
      return null;
    }
  }

  static Future<(int, int)?> _size(String ffprobe, String source) async {
    final remote = source.startsWith('http');
    final result = await _run(
      ffprobe,
      [
        '-v',
        'error',
        if (remote) ...['-rw_timeout', '15000000'],
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height',
        '-of',
        'csv=p=0',
        source,
      ],
      capture: true,
    );
    if (result == null) return null;
    final parts = result.trim().split(',');
    if (parts.length < 2) return null;
    final width = int.tryParse(parts[0]);
    final height = int.tryParse(parts[1]);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width, height);
  }

  static Future<double> _duration(String ffprobe, String source) async {
    final remote = source.startsWith('http');
    final result = await _run(
      ffprobe,
      [
        '-v',
        'error',
        if (remote) ...['-rw_timeout', '15000000'],
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        source,
      ],
      capture: true,
    );
    if (result == null) return 0;
    return double.tryParse(result.trim()) ?? 0;
  }

  /// Runs one ffmpeg/ffprobe invocation with a hard deadline: a stalled
  /// stream must not leave a decoder running for the rest of the session.
  static Future<String?> _run(
    String tool,
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
    bool capture = false,
  }) async {
    final process = await Process.start(tool, args);
    final out = capture ? StringBuffer() : null;
    if (out != null) {
      process.stdout.listen(
        (chunk) => out.write(utf8.decode(chunk, allowMalformed: true)),
      );
      unawaited(process.stderr.drain<void>());
    } else {
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
    }
    try {
      final code = await process.exitCode.timeout(timeout);
      if (code != 0) return null;
      return out?.toString() ?? '';
    } on TimeoutException {
      process.kill();
      return null;
    }
  }
}
