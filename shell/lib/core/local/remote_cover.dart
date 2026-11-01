import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../storage/paths.dart';
import 'local_thumbs.dart';

/// Covers whose bytes Flutter cannot decode (HEIC, AVIF) and that the gateway
/// could not convert are turned into a JPEG once, locally, with the bundled
/// ffmpeg. Proxied covers carry their real address in `src`, so the download
/// goes straight to the image CDN.
class RemoteCover {
  static const int _maxBytes = 8 * 1024 * 1024;
  static const int _maxParallel = 3;

  static final Map<String, String> _paths = {};
  static final Set<String> _failed = {};
  static final Map<String, Future<String?>> _inflight = {};

  static int _running = 0;
  static final List<Completer<void>> _waiting = [];
  static bool _pruned = false;

  static String? cached(String url) => _paths[_key(url)];

  static Future<String?> ensure(String url) {
    _pruneOnce();
    final key = _key(url);
    final known = _paths[key];
    if (known != null) return Future<String?>.value(known);
    if (_failed.contains(key)) return Future<String?>.value(null);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _build(url, key).then((path) {
      if (path == null) {
        _failed.add(key);
      } else {
        _paths[key] = path;
      }
      return path;
    }).whenComplete(() {
      // A block body: an arrow would return the removed future, and
      // whenComplete would then wait for the future it is completing.
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  static String _key(String url) {
    final uri = Uri.tryParse(url);
    final src = uri?.queryParameters['src'];
    final identity = src != null && src.isNotEmpty
        ? src
        : (uri == null ? url : '${uri.scheme}://${uri.host}${uri.path}');
    final parsed = Uri.tryParse(identity);
    final stable = parsed == null ? identity : '${parsed.host}${parsed.path}';
    return sha1.convert(utf8.encode(stable)).toString().substring(0, 16);
  }

  static Directory get _dir {
    final dir = Directory(joinPath(appDataDirectory().path, 'covers'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Keep the converted-cover cache bounded: it only ever holds derived
  /// artwork, so the oldest files are safe to drop.
  static void _pruneOnce() {
    if (_pruned) return;
    _pruned = true;
    try {
      final files = _dir.listSync().whereType<File>().toList();
      if (files.length <= 1200) return;
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      for (final file in files.skip(800)) {
        try {
          file.deleteSync();
        } on Object catch (_) {}
      }
    } on Object catch (_) {}
  }

  static Future<void> _acquire() async {
    if (_running < _maxParallel) {
      _running++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _running--;
  }

  static Future<String?> _build(String url, String key) async {
    final jpg = File(joinPath(_dir.path, '$key.jpg'));
    if (jpg.existsSync() && jpg.lengthSync() > 0) return jpg.path;
    final ffmpeg = LocalThumbs.tool('ffmpeg');
    if (ffmpeg == null) return null;
    await _acquire();
    final source = File(joinPath(_dir.path, '$key.src'));
    try {
      if (!source.existsSync() || source.lengthSync() == 0) {
        final bytes = await _download(url);
        if (bytes == null) return null;
        await source.writeAsBytes(bytes, flush: true);
      }
      final portrait = Uri.tryParse(url)?.queryParameters['fit'] == 'portrait';
      final result = await Process.run(ffmpeg, [
        '-y',
        '-loglevel',
        'error',
        '-i',
        source.path,
        '-frames:v',
        '1',
        if (portrait)
          ...['-vf', 'crop=min(iw\\,ih*3/4):min(ih\\,iw*4/3),scale=400:-2'],
        '-q:v',
        '4',
        jpg.path,
      ]);
      if (result.exitCode != 0 ||
          !jpg.existsSync() ||
          jpg.lengthSync() == 0) {
        debugPrint('cover convert failed: ${result.stderr}');
        return null;
      }
      return jpg.path;
    } on Object catch (error) {
      debugPrint('cover convert failed: $error');
      return null;
    } finally {
      try {
        if (source.existsSync()) source.deleteSync();
      } on Object catch (_) {}
      _release();
    }
  }

  static Future<List<int>?> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final src = uri.queryParameters['src'];
    final target = src != null && src.isNotEmpty ? Uri.parse(src) : uri;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(target);
      request.headers.set(HttpHeaders.userAgentHeader, 'Dart/3.9 (dart:io)');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) return null;
      }
      return bytes;
    } on Object catch (error) {
      debugPrint('cover download failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
