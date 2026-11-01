import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/gateway/core_download.dart';

void main() {
  late HttpServer server;
  late Directory work;
  late List<int> payload;

  setUp(() async {
    work = Directory.systemTemp.createTempSync('core-dl-');
    payload = List<int>.generate(300 * 1024, (i) => i % 251);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/api/core/check') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({
          'version': '1.0.0',
          'url': 'http://127.0.0.1:${server.port}/core.dll',
          'sha256': sha256.convert(payload).toString(),
          'size': payload.length,
        }));
      } else if (request.uri.path == '/core.dll') {
        response.headers.contentLength = payload.length;
        response.add(payload);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      if (work.existsSync()) work.deleteSync(recursive: true);
    } on Object {
      // Windows may hold a handle for a moment; the OS cleans temp up.
    }
  });

  test('downloads, verifies and installs the core', () async {
    final target = '${work.path}${Platform.pathSeparator}freeplayer_core.dll';
    final download = CoreDownload(
      endpoint: 'http://127.0.0.1:${server.port}/api/core/check',
      targetPath: target,
    );
    final events = <String>[];
    final path = await download.ensure(
      onProgress: (received, total) =>
          events.add('$received/$total'),
    );
    expect(path, target);
    expect(File(target).lengthSync(), payload.length);
    expect(sha256.convert(File(target).readAsBytesSync()).toString(),
        sha256.convert(payload).toString());
    expect(events, isNotEmpty);
    expect(
      File('${work.path}${Platform.pathSeparator}freeplayer_core.json')
          .existsSync(),
      isTrue,
    );
  });

  test('removing the source deletes the core and its descriptor', () async {
    final sep = Platform.pathSeparator;
    final target = '${work.path}${sep}freeplayer_core.dll';
    final descriptor = '${work.path}${sep}freeplayer_core.json';
    File(target).writeAsBytesSync([1, 2, 3]);
    File(descriptor).writeAsStringSync('{}');

    await CoreDownload(targetPath: target).removeInstalled();

    expect(File(target).existsSync(), isFalse);
    expect(File(descriptor).existsSync(), isFalse);
  });

  test('a locked core is removed on the next launch', () async {
    final sep = Platform.pathSeparator;
    final target = '${work.path}${sep}freeplayer_core.dll';
    final marker = File('$target.remove');
    File(target).writeAsBytesSync([1, 2, 3]);
    marker.writeAsStringSync('');

    await CoreDownload(targetPath: target).cleanupPendingRemoval();

    expect(File(target).existsSync(), isFalse);
    expect(marker.existsSync(), isFalse);
  });

  test('a matching local build is not downloaded again', () async {
    final target = '${work.path}${Platform.pathSeparator}freeplayer_core.dll';
    final download = CoreDownload(
      endpoint: 'http://127.0.0.1:${server.port}/api/core/check',
      targetPath: target,
    );
    await download.ensure();
    var calls = 0;
    final second = CoreDownload(
      endpoint: 'http://127.0.0.1:${server.port}/api/core/check',
      targetPath: target,
    );
    final path = await second.ensure(onProgress: (_, __) => calls++);
    expect(path, target);
    expect(calls, 0);
  });
}
