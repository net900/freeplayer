import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'cenc_native.dart';

/// Local bridge between the API's encrypted media and the player: the player
/// asks this server for bytes (with Range), the proxy pulls the ciphertext
/// from the API and decrypts it with cenc_decrypt.dll.
///
/// The API never decrypts in this mode and the client never writes a full
/// decrypted copy to disk: only the requested ranges are decrypted in memory.
class DecryptProxy {
  DecryptProxy._();

  static final DecryptProxy instance = DecryptProxy._();

  static const int _maxEntries = 8;
  /// Entries idle for longer than this are dropped on the next registration.
  static const Duration _idleTtl = Duration(minutes: 10);
  static const int _firstHop = 256 * 1024;
  static const int _hop = 2 * 1024 * 1024;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  final Map<String, _ProxyMedia> _media = {};
  final Map<String, String> _bySource = {};
  final List<String> _order = [];
  HttpServer? _server;
  Future<int>? _starting;
  int _sequence = 0;

  bool get available => CencNative.ensureLoaded() != null;

  /// Registers an encrypted URL and returns the loopback URL to play.
  ///
  /// The same URL+key reuses its proxy: the player and the thumbnail builder
  /// ask for the same stream, and a second registration would evict the
  /// playing entry once the cache fills.
  Future<String> register(String url, String keyHex) async {
    final sourceKey = '$url|$keyHex';
    final known = _bySource[sourceKey];
    if (known != null && _media.containsKey(known)) {
      final port = await _ensureServer();
      return 'http://127.0.0.1:$port/v/$known';
    }
    final native = CencNative.ensureLoaded();
    final key = keyFromHex(keyHex);
    if (native == null || key.isEmpty) {
      throw StateError('解密库不可用或密钥无效');
    }
    final media = await _ProxyMedia.open(_client, native, url, key);
    final id = 'm${++_sequence}';
    // Stop the registry growing for episodes nobody is watching any more.
    final cutoff = DateTime.now().subtract(_idleTtl);
    final stale = _media.entries
        .where((entry) => entry.value.lastUsed.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList();
    for (final old in stale) {
      _media.remove(old)?.dispose();
      _order.remove(old);
      _bySource.removeWhere((_, value) => value == old);
    }
    _media[id] = media;
    _bySource[sourceKey] = id;
    _order.add(id);
    while (_order.length > _maxEntries) {
      final old = _order.removeAt(0);
      _media.remove(old)?.dispose();
      _bySource.removeWhere((_, value) => value == old);
    }
    final port = await _ensureServer();
    return 'http://127.0.0.1:$port/v/$id';
  }

  Future<int> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(server.port);
    final starting = _starting;
    if (starting != null) return starting;
    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((s) {
      _server = s;
      s.listen(_handle, onError: (Object _) {});
      return s.port;
    });
    _starting = future;
    return future;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      final media = segments.length == 2 && segments[0] == 'v'
          ? _media[segments[1]]
          : null;
      if (media == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final size = media.size;
      var start = 0;
      var end = size - 1;
      var partial = false;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        final parsed = _parseRange(range, size);
        if (parsed == null) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          await response.close();
          return;
        }
        start = parsed.$1;
        end = parsed.$2;
        partial = true;
      }

      response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
      if (partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      // Small first hop so the player gets its opening bytes quickly, then
      // larger hops to keep upstream request counts low.
      var cursor = start;
      while (cursor <= end) {
        final hop = cursor == start ? _firstHop : _hop;
        var chunkEnd = math.min(cursor + hop - 1, end);
        final span = media.span(cursor, chunkEnd);
        final fetched = await media.fetch(span.start, span.end);
        if (fetched.isEmpty) break;
        if (fetched.length < span.end - span.start + 1) {
          chunkEnd = span.start + fetched.length - 1;
          if (chunkEnd < cursor) break;
        }
        final plain = media.decrypt(fetched, span.start);
        if (plain.isEmpty) break;
        final from = cursor - span.start;
        final to = math.min(chunkEnd, span.end) - span.start + 1;
        if (to > from) response.add(plain.sublist(from, to));
        cursor = math.min(chunkEnd, span.end) + 1;
      }
      await response.close();
    } on Object {
      try {
        await response.close();
      } on Object {
        // The player hung up; nothing left to report.
      }
    }
  }

  static (int, int)? _parseRange(String header, int size) {
    if (!header.startsWith('bytes=')) return null;
    var spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right) ?? 0;
      if (suffix <= 0) return null;
      return (math.max(0, size - suffix), size - 1);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0 || start >= size) return null;
    if (right.isEmpty) return (start, size - 1);
    final end = int.tryParse(right);
    if (end == null || end < start) return null;
    return (start, math.min(end, size - 1));
  }
}

class _ProxyMedia {
  _ProxyMedia._(this._client, this._url, this._key, this.size, this._index);

  // A host that ignores Range answers every request with the whole file. The
  // first such answer is kept and sliced locally: re-downloading 14 MB per
  // range request makes playback unusable. Larger media are not held in RAM.
  static const int _wholeMax = 64 << 20;

  final HttpClient _client;
  final String _url;
  final Uint8List _key;
  final int size;
  final CencIndex _index;
  Uint8List? _whole;
  DateTime lastUsed = DateTime.now();

  static Future<_ProxyMedia> open(
    HttpClient client,
    CencNative native,
    String url,
    Uint8List key,
  ) async {
    final size = await _size(client, url);
    if (size <= 0) throw StateError('无法获取视频大小');
    Uint8List? whole;
    CencIndex? index;
    // A 200 answer already contains the whole file: retrying larger windows
    // would download it again for nothing.
    var complete = false;
    for (final window in [256 << 10, 2 << 20, 8 << 20]) {
      final end = math.min(window, size) - 1;
      final got = await _get(client, url, 0, end);
      complete = got.status == HttpStatus.ok && got.bytes.length >= size;
      if (complete && size <= _wholeMax) whole = got.bytes;
      final data = complete ? _slice(got.bytes, 0, end) : got.bytes;
      index = native.createIndex(data, base: 0, fileSize: size);
      if (index != null || window >= size || complete) break;
    }
    if (index == null && !complete && size > (8 << 20)) {
      final start = size - (8 << 20);
      final got = await _get(client, url, start, size - 1);
      if (got.status == HttpStatus.ok && size <= _wholeMax) {
        whole = got.bytes;
      }
      final source = whole ?? got.bytes;
      final data = got.status == HttpStatus.ok
          ? _slice(source, start, size - 1)
          : got.bytes;
      index = native.createIndex(data, base: start, fileSize: size);
    }
    if (index == null) {
      throw StateError('无法解析视频索引：${native.lastError()}');
    }
    final media = _ProxyMedia._(client, url, key, size, index);
    media._whole = whole;
    return media;
  }

  ({int start, int end}) span(int start, int end) => _index.span(start, end);

  Uint8List decrypt(Uint8List data, int start) => _index.decrypt(data, start, _key);

  Future<Uint8List> fetch(int start, int end) async {
    lastUsed = DateTime.now();
    final whole = _whole;
    if (whole != null) return _slice(whole, start, end);
    final got = await _get(_client, _url, start, end);
    if (got.status == HttpStatus.ok) {
      // Range was ignored: the body starts at offset 0, not at [start].
      if (got.bytes.length >= size && size <= _wholeMax) {
        _whole = got.bytes;
      }
      return _slice(got.bytes, start, end);
    }
    return got.bytes;
  }

  static Uint8List _slice(Uint8List data, int start, int end) {
    if (start >= data.length) return Uint8List(0);
    final stop = math.min(end + 1, data.length);
    return Uint8List.sublistView(data, start, stop);
  }

  void dispose() {
    _whole = null;
    _index.dispose();
  }

  static Future<int> _size(HttpClient client, String url) async {
    try {
      final request = await client.openUrl('HEAD', Uri.parse(url));
      final response = await request.close();
      final length = response.contentLength;
      await response.drain<void>();
      if (length > 0) return length;
    } on Object {
      // Fall through to a one-byte range request.
    }
    final request = await client.openUrl('GET', Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close();
    final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    await response.drain<void>();
    final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  static Future<({Uint8List bytes, int status})> _get(
    HttpClient client,
    String url,
    int start,
    int end,
  ) async {
    final request = await client.openUrl('GET', Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw StateError('上游返回 ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (bytes: builder.takeBytes(), status: response.statusCode);
  }
}
