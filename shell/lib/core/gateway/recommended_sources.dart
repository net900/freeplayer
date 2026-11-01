import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../app/app_config.dart';

/// One entry from the website's curated source list.
class RecommendedSource {
  const RecommendedSource({
    required this.id,
    required this.name,
    required this.url,
    this.kind = 'online',
    this.summary = '',
    this.description = '',
    this.author = '',
    this.sourceId = '',
    this.version = '',
    this.tags = const [],
    this.packageUrl = '',
    this.packageSha256 = '',
    this.packageSize = 0,
    this.packageVersion = '',
  });

  final String id;
  final String name;
  final String url;
  final String kind;
  final String summary;
  final String description;
  final String author;
  final String sourceId;
  final String version;
  final List<String> tags;
  final String packageUrl;
  final String packageSha256;
  final int packageSize;
  final String packageVersion;

  bool get isLocal => kind == 'local-js';

  factory RecommendedSource.fromJson(Map<String, dynamic> json) {
    return RecommendedSource(
      id: _string(json['id']),
      name: _string(json['name']),
      url: _string(json['url']),
      kind: _string(json['kind']).isEmpty ? 'online' : _string(json['kind']),
      summary: _string(json['summary']),
      description: _string(json['description']),
      author: _string(json['author']),
      sourceId: _string(json['source_id']),
      version: _string(json['version']),
      tags: _stringList(json['tags']),
      packageUrl: _string(json['package_url']),
      packageSha256: _string(json['package_sha256']),
      packageSize: json['package_size'] is num
          ? (json['package_size'] as num).toInt()
          : 0,
      packageVersion: _string(json['package_version']),
    );
  }
}

class RecommendedSourcesException implements Exception {
  const RecommendedSourcesException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RecommendedSourcesApi {
  const RecommendedSourcesApi._();

  static Future<List<RecommendedSource>> fetch({
    String endpoint = recommendedSourcesEndpoint,
  }) async {
    final trimmed = endpoint.trim();
    if (trimmed.isEmpty) {
      throw const RecommendedSourcesException('推荐源服务还没有配置。');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const RecommendedSourcesException('推荐源服务地址无效。');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 10);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw RecommendedSourcesException(
          '推荐源服务返回 ${response.statusCode}。',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const RecommendedSourcesException('推荐源服务返回了无效数据。');
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        final message = _string(map['error'] is Map
            ? (map['error'] as Map)['message']
            : map['message']);
        throw RecommendedSourcesException(
          message.isEmpty ? '推荐源服务暂时不可用。' : message,
        );
      }
      final raw = map['sources'];
      if (raw is! List) {
        throw const RecommendedSourcesException('推荐源列表格式不正确。');
      }
      return raw
          .whereType<Map>()
          .map((item) => RecommendedSource.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .where((source) =>
              source.name.isNotEmpty &&
              (source.url.isNotEmpty ||
                  (source.isLocal && source.packageUrl.isNotEmpty)))
          .toList(growable: false);
    } on TimeoutException {
      throw const RecommendedSourcesException('拉取推荐源超时，请稍后再试。');
    } on SocketException {
      throw const RecommendedSourcesException('连接不上推荐源服务，请检查网络。');
    } on FormatException {
      throw const RecommendedSourcesException('推荐源服务返回了无法解析的数据。');
    } finally {
      client.close(force: true);
    }
  }
}

String _string(Object? value) => value is String ? value : '';

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().where((item) => item.isNotEmpty).toList(
        growable: false,
      );
}
