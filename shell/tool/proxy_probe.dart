import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:free_player/core/decryptor/decrypt_proxy.dart';

Future<Map<String, dynamic>> _json(
  HttpClient client,
  String method,
  String url, {
  Map<String, dynamic>? body,
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  request.headers.set('X-Client-Id', 'probe');
  request.headers.set('X-Source-Protocol', '1');
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  final decoded = jsonDecode(text);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

Future<void> main() async {
  final client = HttpClient();
  final base = Platform.environment['FP_PROBE_BASE'] ?? 'http://127.0.0.1:8787';
  final plan = await _json(
    client,
    'POST',
    '$base/v1/hongguo/play',
    body: {
      'item_id': Platform.environment['FP_PROBE_ITEM'] ??
          '7691341476239772696',
      'episode_id': Platform.environment['FP_PROBE_EPISODE'] ??
          '7691443049024457753',
    },
  );
  final stream = (plan['data']['streams'] as List).first as Map;
  final decryption = plan['data']['decryption'] as Map;
  stderr.writeln('enc url: ${stream['url']}');
  stderr.writeln('location=${decryption['location']} key=${decryption['key_hex']}');

  final local = await DecryptProxy.instance.register(
    stream['url'] as String,
    decryption['key_hex'] as String,
  );
  stderr.writeln('local url: $local');

  final request = await client.openUrl('GET', Uri.parse(local));
  final response = await request.close();
  stderr.writeln('local status=${response.statusCode} length=${response.contentLength}');
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  final out = File('../native/cenc/build/proxy_out.mp4');
  out.writeAsBytesSync(bytes);
  stderr.writeln('decrypted ${bytes.length} bytes');

  final ffprobe = Platform.environment['FP_FFPROBE'] ?? 'ffprobe';
  final probe = await Process.run(ffprobe, [
    '-v', 'error',
    '-show_entries', 'format=duration,size',
    '-of', 'default=nw=1',
    out.path,
  ]);
  stderr.writeln('ffprobe rc=${probe.exitCode}');
  stderr.writeln(probe.stdout);
  stderr.writeln(probe.stderr);
  exit(0);
}
