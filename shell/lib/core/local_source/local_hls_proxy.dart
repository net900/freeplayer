import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A loopback HLS proxy for local JS sources.
///
/// The JS source only returns upstream playlist URLs. Dart fetches the
/// playlist with the source's headers, rewrites every URI (variant playlists,
/// keys and segments) to this server, and forwards Range requests. The player
/// never sees the upstream host or its Referer requirements.
class LocalHlsProxy {
  LocalHlsProxy._();

  static final LocalHlsProxy instance = LocalHlsProxy._();

  static const int _maxTokens = 6000;
  static const int _maxStreams = 24;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);
  final Map<String, _HlsStream> _streams = {};
  HttpServer? _server;
  Future<int>? _starting;
  int _sequence = 0;
  final Random _random = Random.secure();

  Future<String> register(String playlistUrl, Map<String, String> headers) async {
    final uri = Uri.tryParse(playlistUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('播放地址无效');
    }
    final id = 'h${++_sequence}';
    _streams[id] = _HlsStream(uri, Map<String, String>.from(headers));
    // Each stream keeps one token per segment; a long binge must not keep
    // every playlist of the session in memory.
    while (_streams.length > _maxStreams) {
      _streams.remove(_streams.keys.first);
    }
    final port = await _ensureServer();
    return 'http://127.0.0.1:$port/p/$id.m3u8';
  }

  Future<int> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(server.port);
    final starting = _starting;
    if (starting != null) return starting;
    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((value) {
      _server = value;
      value.listen(_handle, onError: (Object _) {});
      return value.port;
    });
    _starting = future;
    return future;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length == 2 && segments[0] == 'p') {
        var id = segments[1];
        if (id.endsWith('.m3u8')) {
          id = id.substring(0, id.length - 5);
        }
        await _servePlaylist(id, request, response);
        return;
      }
      if (segments.length == 3 && segments[0] == 'r') {
        await _serveResource(segments[1], segments[2], request, response);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } on Object {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } on Object {
        // The player disconnected.
      }
    }
  }

  Future<void> _servePlaylist(
    String id,
    HttpRequest request,
    HttpResponse response,
  ) async {
    final stream = _streams[id];
    if (stream == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fetched = await _fetch(stream.url, stream.headers);
    if (fetched.status >= 400) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    final text = utf8.decode(fetched.body, allowMalformed: true);
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    final body = _rewrite(id, stream, text, stream.url);
    final bytes = utf8.encode(body);
    response.statusCode = HttpStatus.ok;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
      ..set(HttpHeaders.contentLengthHeader, '${bytes.length}')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method != 'HEAD') response.add(bytes);
    await response.close();
  }

  Future<void> _serveResource(
    String id,
    String token,
    HttpRequest request,
    HttpResponse response,
  ) async {
    final stream = _streams[id];
    final url = stream?.tokens[token];
    if (stream == null || url == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final fetched = await _fetch(url, stream.headers, range: range);
    if (fetched.status >= 400) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    final text = (_looksLikePlaylist(fetched) || _startsWithPlaylist(fetched.body))
        ? utf8.decode(fetched.body, allowMalformed: true)
        : '';
    if (text.trimLeft().startsWith('#EXTM3U')) {
      final body = utf8.encode(_rewrite(id, stream, text, url));
      response.statusCode = HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
        ..set(HttpHeaders.contentLengthHeader, '${body.length}')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method != 'HEAD') response.add(body);
      await response.close();
      return;
    }

    response.statusCode = fetched.status == HttpStatus.partialContent
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    response.headers
      ..set(
        HttpHeaders.contentTypeHeader,
        fetched.contentType ?? 'application/octet-stream',
      )
      ..set(HttpHeaders.contentLengthHeader, '${fetched.body.length}')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'private, max-age=3600');
    final contentRange = fetched.headers['content-range'];
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    if (request.method != 'HEAD') response.add(fetched.body);
    await response.close();
  }

  bool _looksLikePlaylist(_Fetched fetched) {
    final type = (fetched.contentType ?? '').toLowerCase();
    return type.contains('mpegurl') || type.contains('m3u8');
  }

  bool _startsWithPlaylist(Uint8List body) {
    if (body.length < 7) return false;
    final end = body.length < 16 ? body.length : 16;
    return utf8
        .decode(body.sublist(0, end), allowMalformed: true)
        .trimLeft()
        .startsWith('#EXTM3U');
  }

  String _rewrite(
    String id,
    _HlsStream stream,
    String source,
    Uri base,
  ) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    final uriPattern = RegExp(r'URI="([^"]+)"');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        out.add(trimmed.replaceAllMapped(uriPattern, (match) {
          final resolved = base.resolve(match.group(1)!);
          return 'URI="/r/$id/${_tokenFor(stream, resolved)}"';
        }));
        continue;
      }
      final resolved = base.resolve(trimmed);
      out.add('/r/$id/${_tokenFor(stream, resolved)}');
    }
    return out.join('\n');
  }

  String _tokenFor(_HlsStream stream, Uri url) {
    final key = url.toString();
    final existing = stream.byUrl[key];
    if (existing != null) return existing;
    final token = _newToken();
    stream.byUrl[key] = token;
    stream.tokens[token] = url;
    while (stream.tokens.length > _maxTokens) {
      final oldest = stream.tokens.keys.first;
      stream.tokens.remove(oldest);
      stream.byUrl.removeWhere((_, value) => value == oldest);
    }
    return token;
  }

  String _newToken() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<_Fetched> _fetch(
    Uri url,
    Map<String, String> headers, {
    String? range,
  }) async {
    final request = await _client.openUrl('GET', url);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null && range.isNotEmpty) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final builder = await response
        .fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
          builder.add(chunk);
          return builder;
        })
        .timeout(const Duration(seconds: 30));
    final map = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) map[name.toLowerCase()] = values.join(', ');
    });
    return _Fetched(
      status: response.statusCode,
      body: builder.takeBytes(),
      headers: map,
      contentType: response.headers.contentType?.toString(),
    );
  }
}

class _HlsStream {
  _HlsStream(this.url, this.headers);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, String> byUrl = {};
  final Map<String, Uri> tokens = {};
}

class _Fetched {
  const _Fetched({
    required this.status,
    required this.body,
    required this.headers,
    this.contentType,
  });

  final int status;
  final Uint8List body;
  final Map<String, String> headers;
  final String? contentType;
}
