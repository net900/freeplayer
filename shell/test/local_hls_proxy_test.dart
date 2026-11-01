import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/local_source/local_hls_proxy.dart';

void main() {
  test('local HLS proxy rewrites playlists, keys and ranges', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final segment = Uint8List.fromList(List<int>.generate(10, (i) => i));
    upstream.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/master.m3u8':
          response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          response.write(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
            '#EXTINF:1,\n'
            'seg.ts\n',
          );
          break;
        case '/key.bin':
          response.add(List<int>.generate(16, (i) => i));
          break;
        case '/seg.ts':
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range == 'bytes=0-3') {
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes 0-3/${segment.length}',
            );
            response.add(segment.sublist(0, 4));
          } else {
            response.add(segment);
          }
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final local = await LocalHlsProxy.instance.register(
      'http://127.0.0.1:${upstream.port}/master.m3u8',
      const {'Referer': 'https://example.test/'},
    );
    final client = HttpClient();
    try {
      final playlist = await _get(client, local);
      expect(playlist.statusCode, HttpStatus.ok);
      final text = utf8.decode(playlist.body);
      expect(text, contains('#EXTM3U'));
      expect(text, contains('URI="/r/'));
      expect(text, isNot(contains('key.bin')));
      expect(text, isNot(contains('seg.ts')));

      final keyUri = RegExp(r'URI="([^"]+)"').firstMatch(text)!.group(1)!;
      final key = await _get(client, local.replaceFirst('/p/', '/').split('/h1.m3u8').first + keyUri);
      expect(key.statusCode, HttpStatus.ok);
      expect(key.body, List<int>.generate(16, (i) => i));

      final segmentUri = text
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.startsWith('/r/'));
      final audio = await _get(
        client,
        local.replaceFirst('/p/', '/').split('/h1.m3u8').first + segmentUri,
        range: 'bytes=0-3',
      );
      expect(audio.statusCode, HttpStatus.partialContent);
      expect(audio.headers['content-range'], 'bytes 0-3/10');
      expect(audio.body, [0, 1, 2, 3]);
    } finally {
      client.close(force: true);
      await upstream.close(force: true);
    }
  });
}

Future<_Response> _get(HttpClient client, String url, {String? range}) async {
  final request = await client.getUrl(Uri.parse(url));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  final response = await request.close();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    if (values.isNotEmpty) {
      headers[name.toLowerCase()] = values.join(', ');
    }
  });
  return _Response(
    statusCode: response.statusCode,
    headers: headers,
    body: builder.takeBytes(),
  );
}

class _Response {
  const _Response({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
}
