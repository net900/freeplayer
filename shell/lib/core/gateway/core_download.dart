import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../app/app_config.dart';
import '../logging/app_log.dart';
import '../storage/paths.dart';
import 'local_core.dart';

/// The source core is distributed like an app update: the website only
/// announces a version and the client downloads the DLL itself, verifies it
/// and loads it in-process. The same file also carries the CENC decryptor,
/// so a source needs exactly one download.
class CoreDownload {
  CoreDownload({this.endpoint = coreCheckEndpoint, this.targetPath});

  final String endpoint;

  /// Test seam: where the DLL is installed. Defaults to `decryptors\` beside
  /// the executable, which is where the app loads it from.
  final String? targetPath;

  static const Duration _timeout = Duration(seconds: 8);
  static const int _maxManifest = 64 * 1024;

  /// Returns the installed core path, downloading it when the local copy is
  /// missing or differs from the announced build. Never throws: a failed
  /// update leaves the previous DLL in place.
  /// How long a build that failed verification is left alone. A proxy serving
  /// stale bytes against a fresh digest would otherwise make every launch
  /// download the same 10 MB again.
  static const Duration _retryAfterFailure = Duration(minutes: 30);

  Future<String?> ensure({
    void Function(int received, int total)? onProgress,
    void Function()? onReplaced,
    void Function()? onUpdateStart,
  }) async {
    await cleanupPendingRemoval();
    final installed = _installedPath();
    final manifest = await _check();
    if (manifest == null) return installed;
    final target = installed ?? _targetPath();
    final current = await _sha256Of(File(target));
    // A manifest without a digest cannot be verified; keeping the installed
    // copy beats downloading one that would be rejected every launch.
    if (manifest.sha256.isEmpty) {
      return current != null ? target : installed;
    }
    if (current != null && current == manifest.sha256.toLowerCase()) {
      _writeDescriptor(manifest);
      return target;
    }
    if (_recentFailure(manifest.sha256)) return installed;
    onUpdateStart?.call();
    final result = await _download(manifest, target, onProgress);
    if (result.path != null) {
      _writeDescriptor(manifest);
      onReplaced?.call();
      return result.path;
    }
    // A verified build that could not be put in place (a previous process is
    // still letting go of the DLL after an installer relaunch) is not a bad
    // build: retrying on the next launch beats suppressing it for half an
    // hour, which left the stale core running against a changed protocol.
    if (result.replaceFailed) {
      AppLog.write('core update: could not replace the installed DLL');
    } else {
      _writeFailure(manifest);
    }
    return File(target).existsSync() ? target : null;
  }

  Map<String, dynamic>? _readDescriptor() {
    try {
      final file = File(joinPath(
        Directory(File(_targetPath()).parent.path).path,
        'freeplayer_core.json',
      ));
      if (!file.existsSync()) return null;
      final value = jsonDecode(file.readAsStringSync());
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } on Object {
      return null;
    }
  }

  bool _recentFailure(String sha256) {
    final descriptor = _readDescriptor();
    if (descriptor == null) return false;
    if (descriptor['failed_sha256'] != sha256.toLowerCase()) return false;
    final at = descriptor['failed_at'];
    if (at is! int) return false;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    return age >= 0 && age < _retryAfterFailure.inMilliseconds;
  }

  void _writeFailure(CoreManifest manifest) {
    final descriptor = _readDescriptor() ?? <String, dynamic>{};
    descriptor
      ..['version'] = manifest.version
      ..['url'] = manifest.url
      ..['sha256'] = manifest.sha256
      ..['size'] = manifest.size
      ..['failed_sha256'] = manifest.sha256
      ..['failed_at'] = DateTime.now().millisecondsSinceEpoch;
    _writeJson(descriptor);
  }

  Future<CoreManifest?> _check() async {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) return null;
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > _maxManifest) return null;
      }
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (value is! Map) return null;
      var map = Map<String, dynamic>.from(value);
      // The source gateway wraps payloads in {code,message,data}; a plain
      // static manifest answers bare JSON. Accept both.
      if (map['data'] is Map) {
        final code = map['code'];
        if (code is int && code != 0) return null;
        map = Map<String, dynamic>.from(map['data'] as Map);
      }
      return CoreManifest.fromJson(map);
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<({String? path, bool replaceFailed})> _download(
    CoreManifest manifest,
    String target,
    void Function(int, int)? onProgress,
  ) async {
    final dir = Directory(File(target).parent.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final temp = File('$target.part');
    for (final url in [manifest.url, manifest.mirror]) {
      if (url.isEmpty) continue;
      try {
        await _fetch(url, temp, manifest, onProgress);
        final digest = await _sha256Of(temp);
        if (digest == null || digest != manifest.sha256.toLowerCase()) {
          AppLog.write(
            'core update: digest mismatch '
            '${digest ?? "null"} != ${manifest.sha256}',
          );
          await _delete(temp);
          continue;
        }
        if (await _replace(temp, target)) {
          return (path: target, replaceFailed: false);
        }
        await _delete(temp);
        return (path: null, replaceFailed: true);
      } on Object catch (error) {
        AppLog.write('core update: download failed: $error');
        await _delete(temp);
      }
    }
    return (path: null, replaceFailed: false);
  }

  /// The installer relaunches the app right after closing the previous
  /// process, and Windows keeps the mapped DLL busy for a moment after that:
  /// replacing it then fails with a sharing violation. A few short retries
  /// close that window instead of leaving the old core in place.
  Future<bool> _replace(File temp, String target) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        if (File(target).existsSync()) await File(target).delete();
        await temp.rename(target);
        return true;
      } on FileSystemException catch (error) {
        AppLog.write(
          'core update: replace attempt ${attempt + 1} failed: $error',
        );
        await Future<void>.delayed(
          Duration(milliseconds: 300 + attempt * 200),
        );
      }
    }
    return false;
  }

  Future<void> _fetch(
    String url,
    File temp,
    CoreManifest manifest,
    void Function(int, int)? onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(
            const Duration(seconds: 15),
          );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : manifest.size;
      final sink = temp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (manifest.size > 0 && received != manifest.size) {
        throw const HttpException('incomplete download');
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes the installed core after its source was removed. A loaded DLL
  /// stays locked on Windows; its marker is retried on the next launch.
  Future<void> removeInstalled() async {
    final targets = <String>{_targetPath()};
    final installed = _installedPath();
    if (installed != null) targets.add(installed);
    for (final target in targets) {
      final descriptor =
          joinPath(File(target).parent.path, 'freeplayer_core.json');
      for (final path in [target, '$target.part', descriptor]) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on Object {
          // Locked or already gone.
        }
      }
      if (await File(target).exists()) {
        try {
          await File('$target.remove').writeAsString('');
        } on Object {
          // Nothing else can be done now.
        }
      }
    }
  }

  Future<void> cleanupPendingRemoval() async {
    final targets = <String>{_targetPath()};
    final installed = _installedPath();
    if (installed != null) targets.add(installed);
    for (final target in targets) {
      final marker = File('$target.remove');
      if (!await marker.exists()) continue;
      final descriptor =
          joinPath(File(target).parent.path, 'freeplayer_core.json');
      var cleared = true;
      for (final path in [target, '$target.part', descriptor]) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on Object {
          cleared = false;
          break;
        }
      }
      if (!cleared) continue; // Still loaded; keep the marker.
      try {
        await marker.delete();
      } on Object {
        // Best effort.
      }
    }
  }

  static Future<String?> _sha256Of(File file) async {
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString().toLowerCase();
    } on Object {
      return null;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on Object {
      // Best effort: a stray .part file is harmless.
    }
  }

  /// The app loads the core from `decryptors\` first; keep the download there.
  String _targetPath() =>
      targetPath ??
      joinPath(
        joinPath(File(Platform.resolvedExecutable).parent.path, 'decryptors'),
        LocalCore.libraryName,
      );

  String? _installedPath() {
    final explicit = targetPath;
    if (explicit != null) {
      return File(explicit).existsSync() ? explicit : null;
    }
    return LocalCore.findLibrary();
  }

  void _writeDescriptor(CoreManifest manifest) {
    _writeJson({
      'version': manifest.version,
      'url': manifest.url,
      'sha256': manifest.sha256,
      'size': manifest.size,
    });
  }

  void _writeJson(Map<String, dynamic> payload) {
    try {
      final dir = Directory(File(_targetPath()).parent.path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(joinPath(dir.path, 'freeplayer_core.json'))
          .writeAsStringSync(jsonEncode(payload));
    } on Object {
      // A missing descriptor only costs one redundant check next launch.
    }
  }
}

/// What the shell shows while the core is downloading.
class CoreDownloadState {
  const CoreDownloadState({required this.received, required this.total});

  final int received;
  final int total;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  String get label {
    final got = (received / (1 << 20)).toStringAsFixed(1);
    if (total <= 0) return '正在下载资源核心 $got MB';
    final all = (total / (1 << 20)).toStringAsFixed(1);
    final pct = (received * 100 / total).clamp(0, 100).toStringAsFixed(0);
    return '正在下载资源核心 $got / $all MB（$pct%）';
  }
}

class CoreManifest {
  const CoreManifest({
    this.version = '',
    this.url = '',
    this.mirror = '',
    this.sha256 = '',
    this.size = 0,
  });

  final String version;
  final String url;
  final String mirror;
  final String sha256;
  final int size;

  static CoreManifest? fromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? '').toString();
    if (url.isEmpty) return null;
    return CoreManifest(
      version: (json['version'] ?? '').toString(),
      url: url,
      mirror: (json['mirror'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString().toLowerCase(),
      size: json['size'] is int
          ? json['size'] as int
          : int.tryParse('${json['size'] ?? ''}') ?? 0,
    );
  }
}
