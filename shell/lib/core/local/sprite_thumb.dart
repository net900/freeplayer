import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../storage/paths.dart';
import 'local_thumbs.dart';

/// A local copy of a source's preview sprite.
class SpriteImage {
  const SpriteImage(this.path, this.width, this.height);

  final String path;
  final int width;
  final int height;
}

/// Downloads the progress-bar sprite and converts it to a JPEG with the
/// ffmpeg shipped beside the app. The source only supplies an address; the
/// sheet's grid is the client's business. Keyed by host+path because the
/// source re-signs its links.
class RemoteSprite {
  static const int _maxBytes = 24 * 1024 * 1024;

  static final Map<String, SpriteImage> _images = {};
  static final Map<String, Future<SpriteImage?>> _inflight = {};

  static SpriteImage? cached(String url) => _images[_key(url)];

  /// Returns a cached conversion, otherwise converts once and shares that
  /// future with every concurrent caller. Returning null for an in-flight
  /// request used to make the player give up permanently when the prefetcher
  /// happened to be converting the same sheet.
  static Future<SpriteImage?> ensure(String url) {
    final key = _key(url);
    final known = _images[key];
    if (known != null) return Future<SpriteImage?>.value(known);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _build(url, key).then((image) {
      if (image != null) _images[key] = image;
      return image;
    }).whenComplete(() {
      // Block body on purpose: whenComplete waits on a returned future, and
      // an arrow would hand back the future it is completing.
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  static String _key(String url) {
    final uri = Uri.tryParse(url);
    final identity = uri == null ? url : '${uri.host}${uri.path}';
    return sha1.convert(utf8.encode(identity)).toString().substring(0, 16);
  }

  static bool _pruned = false;

  static Directory get _dir {
    final dir = Directory(joinPath(appDataDirectory().path, 'sprites'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (!_pruned) {
      _pruned = true;
      pruneCacheDirectory(dir);
    }
    return dir;
  }

  static Future<SpriteImage?> _build(String url, String key) async {
    final jpg = File(joinPath(_dir.path, '$key.jpg'));
    if (!jpg.existsSync() || jpg.lengthSync() == 0) {
      final ffmpeg = LocalThumbs.tool('ffmpeg');
      if (ffmpeg == null) return null;
      final source = File(joinPath(_dir.path, '$key.src'));
      try {
        if (!source.existsSync() || source.lengthSync() == 0) {
          final bytes = await _download(url);
          if (bytes == null) return null;
          await source.writeAsBytes(bytes, flush: true);
        }
        final result = await Process.run(ffmpeg, [
          '-y',
          '-loglevel',
          'error',
          '-i',
          source.path,
          '-frames:v',
          '1',
          '-q:v',
          '4',
          jpg.path,
        ]);
        if (result.exitCode != 0 ||
            !jpg.existsSync() ||
            jpg.lengthSync() == 0) {
          return null;
        }
      } on Object catch (error) {
        debugPrint('remote sprite failed: $error');
        return null;
      } finally {
        try {
          if (source.existsSync()) source.deleteSync();
        } on Object catch (_) {}
      }
    }
    final size = await _size(jpg.path);
    if (size == null) return null;
    return SpriteImage(jpg.path, size.$1, size.$2);
  }

  static Future<(int, int)?> _size(String path) async {
    final ffprobe = LocalThumbs.tool('ffprobe');
    if (ffprobe == null) return null;
    try {
      final result = await Process.run(ffprobe, [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height',
        '-of',
        'csv=p=0',
        path,
      ]);
      if (result.exitCode != 0) return null;
      final parts = result.stdout.toString().trim().split(',');
      if (parts.length < 2) return null;
      final width = int.tryParse(parts[0]);
      final height = int.tryParse(parts[1]);
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      return (width, height);
    } on Object catch (error) {
      debugPrint('sprite size failed: $error');
      return null;
    }
  }

  static Future<List<int>?> _download(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) return null;
      }
      return bytes;
    } on Object catch (error) {
      debugPrint('sprite download failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
