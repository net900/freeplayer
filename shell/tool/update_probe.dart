// Exercises the update service end to end: check → download → SHA-256 →
// extract, exactly the path `UpdateService` takes inside the app, but without
// importing Flutter so it runs with plain `dart run`.
//
//   dart run tool/update_probe.dart
//   dart run tool/update_probe.dart https://freeplayer.8a5.cn/api/update/check
//
// The endpoint defaults to the one the app was built with (FP_UPDATE_URL).
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:free_player/app/app_config.dart';
import 'package:free_player/core/update/update_info.dart';

const int _maxPackageBytes = 512 << 20;

Future<void> main(List<String> args) async {
  final endpoint = args.isNotEmpty ? args.first : updateCheckEndpoint;
  final base = Uri.tryParse(endpoint);
  if (base == null || !base.hasScheme) {
    stderr.writeln('invalid endpoint: $endpoint');
    exit(2);
  }
  final uri = base.replace(queryParameters: {
    ...base.queryParameters,
    'platform': 'win64',
    'version': appVersion,
    'channel': updateChannel,
  });
  stdout.writeln('check: $uri');

  final payload = await _getJson(uri);
  if (payload == null) exit(1);
  final info = UpdateInfo.parse(payload);
  if (info == null) {
    stdout.writeln(
      'no update for $appVersion ($updateChannel): '
      'update_available=${payload['update_available']} '
      'notify=${payload['notify']} reason=${payload['reason'] ?? '-'}',
    );
    return;
  }
  stdout.writeln('latest: ${info.version}  ${info.downloadUrl}');
  if (info.sha256.isNotEmpty) stdout.writeln('sha256: ${info.sha256}');

  final work = Directory.systemTemp.createTempSync('freeplayer-probe-');
  final package = File('${work.path}${Platform.pathSeparator}package.zip');
  var downloaded = false;
  for (final url in [info.downloadUrl, info.mirrorUrl]) {
    if (url.isEmpty) continue;
    try {
      await _download(Uri.parse(url), package);
      downloaded = true;
      break;
    } on Object catch (error) {
      stderr.writeln('download failed ($url): $error');
    }
  }
  if (!downloaded) {
    stderr.writeln('no download URL worked');
    exit(1);
  }

  final bytes = package.readAsBytesSync();
  if (info.size > 0 && bytes.length != info.size) {
    stderr.writeln('size mismatch: ${bytes.length} != ${info.size}');
    exit(1);
  }
  if (info.sha256.isNotEmpty) {
    final digest = sha256.convert(bytes).toString().toLowerCase();
    if (digest != info.sha256.toLowerCase()) {
      stderr.writeln('sha256 mismatch: $digest');
      exit(1);
    }
    stdout.writeln('verified ${bytes.length} bytes');
  }

  final stage = Directory('${work.path}${Platform.pathSeparator}stage')
    ..createSync(recursive: true);
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final entry in archive) {
    final name = entry.name.replaceAll('\\', '/');
    if (name.startsWith('/') || name.split('/').contains('..')) {
      stderr.writeln('skipping unsafe entry: ${entry.name}');
      continue;
    }
    final target = File('${stage.path}${Platform.pathSeparator}$name');
    if (entry.isFile) {
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
    }
  }
  stdout.writeln('stage: ${stage.path}');
  final entries = stage.listSync()..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries.take(8)) {
    stdout.writeln('  ${entry.path.split(Platform.pathSeparator).last}');
  }
}

Future<Map<String, dynamic>?> _getJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response =
        await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('HTTP ${response.statusCode}');
      return null;
    }
    final text = await response.transform(utf8.decoder).join();
    final value = jsonDecode(text);
    if (value is! Map) {
      stderr.writeln('unexpected payload: ${text.length > 200 ? text.substring(0, 200) : text}');
      return null;
    }
    return Map<String, dynamic>.from(value);
  } on Object catch (error) {
    stderr.writeln('check failed: $error');
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<void> _download(Uri uri, File target) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final response =
        await (await client.getUrl(uri).timeout(const Duration(seconds: 15)))
            .close()
            .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > _maxPackageBytes) {
          throw const HttpException('package too large');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    stdout.writeln('downloaded $received bytes');
  } finally {
    client.close(force: true);
  }
}
