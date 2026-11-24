import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'cenc_native.dart';

/// Local bridge between the API's encrypted media and the player: the player
/// asks this server for bytes (with Range), the proxy pulls the ciphertext
/// from the API and decrypts it with cenc_decrypt.dll.
///
/// The server, the MP4 index and every decryption call run in a dedicated
/// isolate. Decrypting a few megabytes synchronously used to happen on the UI
/// isolate, which is exactly what produced hitches while scrubbing.
///
/// The API never decrypts in this mode and the client never writes a full
/// decrypted copy to disk: only the requested ranges are decrypted in memory.
class DecryptProxy {
  DecryptProxy._();

  static final DecryptProxy instance = DecryptProxy._();

  /// Builds a proxy entry for an episode that is only queued: opening it
  /// probes the size and fetches the moov window from the CDN, which then no
  /// longer happens during the switch.
  static void warm(String url, String keyHex) {
    if (url.isEmpty || keyHex.isEmpty) return;
    unawaited(() async {
      try {
        await instance.register(url, keyHex);
      } on Object {
        // The real open registers again and reports its own failure.
      }
    }());
  }

  SendPort? _calls;
  Future<SendPort>? _starting;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

  /// UA the reference client sends when pulling media directly from the CDN.
  static const String videoUserAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  /// Direct-pull headers shared with the mpv path: the CDN sees the video UA
  /// and `identity` keeps the MP4 bytes uncompressed.
  static Map<String, String> mediaHeaders(Uri uri) => {
        HttpHeaders.userAgentHeader: videoUserAgent,
        HttpHeaders.acceptEncodingHeader: 'identity',
      };

  Future<SendPort> _ensureWorker() {
    final calls = _calls;
    if (calls != null) return Future.value(calls);
    final starting = _starting;
    if (starting != null) return starting;
    final future = _start();
    _starting = future;
    return future;
  }

  Future<SendPort> _start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    replies.listen(
      (message) {
        if (message is List && message.isNotEmpty && message[0] == 'exit') {
          _failPending();
          if (!ready.isCompleted) {
            ready.completeError(StateError('解密进程已停止'));
          }
          return;
        }
        if (message is! List || message.length < 2) return;
        if (message[0] == 'ready') {
          final port = message[1] as SendPort;
          _calls = port;
          if (!ready.isCompleted) ready.complete(port);
          return;
        }
        if (message[0] == 'reply') {
          final id = message[1] as int;
          final pending = _pending.remove(id);
          if (pending == null) return;
          if (message[2] == true) {
            pending.complete(message[3]);
          } else {
            pending.completeError(StateError('${message[3]}'));
          }
        }
      },
      onDone: _failPending,
    );
    try {
      final isolate = await Isolate.spawn(
        _proxyWorkerMain,
        replies.sendPort,
        debugName: 'fp-decrypt-proxy',
      );
      isolate.addOnExitListener(replies.sendPort, response: const ['exit']);
    } on Object catch (error, stack) {
      _starting = null;
      if (!ready.isCompleted) ready.completeError(error, stack);
    }
    return ready.future;
  }

  void _failPending() {
    _calls = null;
    _starting = null;
    final error = StateError('解密进程已停止');
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  Future<Object?> _send(String operation, List<Object?> args) async {
    final calls = await _ensureWorker();
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    calls.send(['call', id, operation, ...args]);
    return completer.future;
  }

  /// Registers an encrypted URL and returns the loopback URL to play.
  Future<String> register(String url, String keyHex) async {
    final result = await _send('register', [url, keyHex]);
    return result as String;
  }
}

// ---------------------------------------------------------------- worker

Future<void> _proxyWorkerMain(SendPort reply) async {
  final calls = ReceivePort();
  final registry = _ProxyRegistry();
  reply.send(['ready', calls.sendPort]);
  await for (final message in calls) {
    if (message is! List || message.length < 3) continue;
    final id = message[1] as int;
    try {
      if (message[0] != 'call') continue;
      final operation = message[2] as String;
      if (operation == 'register') {
        final url = message[3] as String;
        final key = message[4] as String;
        final result = await registry.register(url, key);
        reply.send(['reply', id, true, result]);
      } else if (operation == 'available') {
        reply.send(['reply', id, true, _ProxyRegistry.available]);
      } else {
        reply.send(['reply', id, false, '未知解密操作']);
      }
    } on Object catch (error) {
      reply.send(['reply', id, false, '$error']);
    }
  }
}

class _ProxyRegistry {
  static const int _maxEntries = 8;
  static const Duration _idleTtl = Duration(minutes: 10);
  static const int _firstHop = 256 * 1024;
  static const int _hop = 2 * 1024 * 1024;

  static bool get available => CencNative.ensureLoaded() != null;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  final Map<String, _ProxyMedia> _media = {};
  final Map<String, String> _bySource = {};
  HttpServer? _server;
  Future<int>? _starting;
  int _sequence = 0;

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
      _bySource.removeWhere((_, value) => value == old);
    }
    _media[id] = media;
    _bySource[sourceKey] = id;
    _evictIfNeeded();
    final port = await _ensureServer();
    return 'http://127.0.0.1:$port/v/$id';
  }

  /// Keeps the registry bounded without dropping the stream that is playing
  /// right now. Entries touched in the last 30 seconds are protected; only
  /// when every entry is hot does the least recently used one go. Eviction
  /// used to follow insertion order, so a burst of preloads could remove the
  /// entry whose ranges the player was still requesting.
  void _evictIfNeeded() {
    if (_media.length <= _maxEntries) return;
    final now = DateTime.now();
    String? victim;
    DateTime? oldest;
    for (final entry in _media.entries) {
      if (now.difference(entry.value.lastUsed) < const Duration(seconds: 30)) {
        continue;
      }
      if (oldest == null || entry.value.lastUsed.isBefore(oldest)) {
        oldest = entry.value.lastUsed;
        victim = entry.key;
      }
    }
    if (victim == null) {
      for (final entry in _media.entries) {
        if (oldest == null || entry.value.lastUsed.isBefore(oldest)) {
          oldest = entry.value.lastUsed;
          victim = entry.key;
        }
      }
    }
    if (victim == null) return;
    _media.remove(victim)?.dispose();
    _bySource.removeWhere((_, value) => value == victim);
    _evictIfNeeded();
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
      response.headers
          .set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
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
        if (to > from) {
          // A view, not a copy: the plaintext buffer is already fresh.
          response.add(Uint8List.sublistView(plain, from, to));
          // Wait for the socket before decrypting the next hop. Without this
          // the proxy raced ahead of the player, decrypting the rest of the
          // file into memory.
          await response.flush();
        }
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
  // The head fetched while locating moov is kept: the player asks for exactly
  // that range next, and serving it from memory saves a CDN round trip on
  // every open and episode switch.
  Uint8List? _head;
  DateTime lastUsed = DateTime.now();

  static Future<_ProxyMedia> open(
    HttpClient client,
    CencNative native,
    String url,
    Uint8List key,
  ) async {
    // Size discovery and the first head fetch run together: waiting for the
    // HEAD round trip before every episode switch was the bulk of the
    // one-second delay between episodes.
    final sizeProbe = _size(client, url);
    Uint8List? whole;
    CencIndex? index;
    // A 200 answer already contains the whole file: retrying larger windows
    // would download it again for nothing.
    var complete = false;
    var size = 0;
    Uint8List? head;
    for (final window in [256 << 10, 2 << 20, 8 << 20]) {
      final end = size > 0 ? math.min(window, size) - 1 : window - 1;
      final got = await _get(client, url, 0, end);
      if (size <= 0) {
        size = await sizeProbe;
        if (size <= 0) throw StateError('无法获取视频大小');
      }
      complete = got.status == HttpStatus.ok && got.bytes.length >= size;
      if (complete && size <= _wholeMax) whole = got.bytes;
      final data = complete ? _slice(got.bytes, 0, end) : got.bytes;
      head ??= data;
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
    media._head = head;
    return media;
  }

  ({int start, int end}) span(int start, int end) => _index.span(start, end);

  Uint8List decrypt(Uint8List data, int start) =>
      _index.decrypt(data, start, _key);

  Future<Uint8List> fetch(int start, int end) async {
    lastUsed = DateTime.now();
    final whole = _whole;
    if (whole != null) return _slice(whole, start, end);
    final head = _head;
    if (head != null && start < head.length && end < head.length) {
      return _slice(head, start, end);
    }
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
    final uri = Uri.parse(url);
    try {
      final request = await client.openUrl('HEAD', uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        DecryptProxy.videoUserAgent,
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      final length = response.contentLength;
      await response.drain<void>();
      if (length > 0) return length;
    } on Object {
      // Fall through to a one-byte range request.
    }
    var response = await _openMediaGet(client, uri, 0, 0);
    if (response.statusCode == HttpStatus.forbidden) {
      await response.drain<void>();
      response = await _openMediaGet(client, uri, 0, 0, withReferer: true);
    }
    final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    await response.drain<void>();
    final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// A range GET with the media headers. [withReferer] is the one-shot retry
  /// for edges that answer 403 until a Referer is present.
  static Future<HttpClientResponse> _openMediaGet(
    HttpClient client,
    Uri uri,
    int start,
    int end, {
    bool withReferer = false,
  }) async {
    final request = await client.openUrl('GET', uri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    request.headers.set(
      HttpHeaders.userAgentHeader,
      DecryptProxy.videoUserAgent,
    );
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (withReferer) {
      final referer = uri.hasScheme && uri.host.isNotEmpty
          ? '${uri.scheme}://${uri.host}/'
          : null;
      if (referer != null) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      }
    }
    return request.close();
  }

  static Future<({Uint8List bytes, int status})> _get(
    HttpClient client,
    String url,
    int start,
    int end,
  ) async {
    final uri = Uri.parse(url);
    var response = await _openMediaGet(client, uri, start, end);
    if (response.statusCode == HttpStatus.forbidden) {
      // Some edges only answer once a Referer is present; retry exactly once.
      await response.drain<void>();
      response =
          await _openMediaGet(client, uri, start, end, withReferer: true);
    }
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
