import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../sp/models.dart';
import '../storage/paths.dart';

/// Builds a seek-bar preview sprite for a local file with ffmpeg, cached next
/// to the app data. Sources normally ship their own sprite; a downloaded or
/// opened file has none, so this fills the gap when ffmpeg is installed.
class LocalThumbs {
  static const int cols = 5;
  static const int rows = 4;
  static const int count = cols * rows;
  static const int tileWidth = 160;
  static const int tileHeight = 90;

  static final Map<String, ThumbStrip> _memory = {};
  static final Set<String> _loading = {};

  static Directory get _dir {
    final dir = Directory(joinPath(appDataDirectory().path, 'local_thumbs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _keyFor(String path) {
    final name = path.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return name.length > 80 ? name.substring(name.length - 80) : name;
  }

  /// Returns a cached strip immediately, otherwise generates it in the
  /// background and returns null.
  static ThumbStrip? cached(String path) => _memory[path];

  static Future<ThumbStrip?> load(String path) async {
    final known = _memory[path];
    if (known != null) return known;
    // A previous failure must not poison the cache for the session.
    if (_loading.contains(path)) return null;
    _loading.add(path);
    try {
      return await _build(path);
    } finally {
      _loading.remove(path);
    }
  }

  static Future<ThumbStrip?> _build(String path) async {
    if (!File(path).existsSync()) return null;
    try {
      final ffmpeg = _which('ffmpeg');
      final ffprobe = _which('ffprobe');
      if (ffmpeg == null || ffprobe == null) return null;
      final duration = await _duration(ffprobe, path);
      if (duration <= 1) return null;
      final sprite = File(joinPath(_dir.path, '${_keyFor(path)}.jpg'));
      final meta = File(joinPath(_dir.path, '${_keyFor(path)}.json'));
      if (sprite.existsSync() && meta.existsSync()) {
        final strip = ThumbStrip.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(await meta.readAsString()) as Map,
          ),
        );
        if (strip.valid) {
          _memory[path] = strip;
          return strip;
        }
      }
      final interval = (duration / count).clamp(1.0, 600.0);
      final filter = 'fps=1/${interval.toStringAsFixed(3)},'
          'scale=$tileWidth:$tileHeight:force_original_aspect_ratio=decrease,'
          'pad=$tileWidth:$tileHeight:(ow-iw)/2:(oh-ih)/2,'
          'tile=${cols}x$rows';
      final result = await Process.run(ffmpeg, [
        '-y',
        '-loglevel',
        'error',
        '-i',
        path,
        '-vf',
        filter,
        '-frames:v',
        '1',
        sprite.path,
      ]);
      if (result.exitCode != 0 || !sprite.existsSync()) return null;
      final strip = ThumbStrip(
        url: sprite.path,
        cols: cols,
        rows: rows,
        count: count,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        intervalSec: interval,
      );
      await meta.writeAsString(jsonEncode({
        'url': sprite.path,
        'cols': cols,
        'rows': rows,
        'count': count,
        'tile_width': tileWidth,
        'tile_height': tileHeight,
        'interval_sec': interval,
      }));
      _memory[path] = strip;
      return strip;
    } on Object catch (error) {
      debugPrint('local thumbs failed: $error');
      return null;
    }
  }

  /// ffmpeg/ffprobe shipped beside the app, or one from PATH. Shared with the
  /// remote sprite converter.
  static String? tool(String name) => _which(name);

  static String? _which(String name) {
    final env = Platform.environment['${name.toUpperCase()}_PATH'];
    if (env != null && env.isNotEmpty) return env;
    final exts = Platform.isWindows ? ['.exe', ''] : [''];
    // The installer ships ffmpeg/ffprobe in tools beside the app.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final dir in [joinPath(exeDir, 'tools'), exeDir]) {
      for (final ext in exts) {
        final candidate = File(joinPath(dir, '$name$ext'));
        if (candidate.existsSync()) return candidate.path;
      }
    }
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final candidate = File(joinPath(dir, '$name$ext'));
        if (candidate.existsSync()) return candidate.path;
      }
    }
    return null;
  }

  static Future<double> _duration(String ffprobe, String path) async {
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      path,
    ]);
    if (result.exitCode != 0) return 0;
    return double.tryParse(result.stdout.toString().trim()) ?? 0;
  }
}
