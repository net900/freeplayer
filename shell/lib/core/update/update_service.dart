import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../app/app_config.dart';
import '../logging/app_log.dart';
import 'update_info.dart';

/// Result of one silent check. Failures stay silent for the caller.
class UpdateCheck {
  const UpdateCheck({this.info, this.failed = false});

  final UpdateInfo? info;
  final bool failed;

  static const UpdateCheck none = UpdateCheck();
  static const UpdateCheck error = UpdateCheck(failed: true);
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Download result handed to update.exe, or the installer to run.
class UpdateStage {
  const UpdateStage({
    required this.sourceDir,
    required this.workDir,
    this.installerPath = '',
  });

  final String sourceDir;
  final String workDir;

  /// Set when the release is an installer (Setup.exe) instead of a portable
  /// zip: it replaces the files itself, so nothing is extracted.
  final String installerPath;

  bool get isInstaller => installerPath.isNotEmpty;
}

class UpdateService {
  static const Duration _timeout = Duration(seconds: 8);

  static bool get isBeta => updateChannel == 'beta';

  /// Silent check. Any failure returns [UpdateCheck.error] and must not be
  /// shown to the user.
  static Future<UpdateCheck> check({String declinedKey = ''}) async {
    final base = Uri.tryParse(updateCheckEndpoint);
    if (base == null || !base.hasScheme) return UpdateCheck.error;
    final uri = base.replace(queryParameters: {
      ...base.queryParameters,
      'platform': 'win64',
      'version': appVersion,
      'channel': updateChannel,
      if (declinedKey.isNotEmpty) 'declined': declinedKey,
    });
    debugPrint('update check: $uri');
    AppLog.write('update check: $uri');
    // The site occasionally drops a connection outright (measured 2026-11-01:
    // two of four requests timed out on a healthy link). One silent retry, so
    // a dropped connection does not cost the user a whole release.
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await _request(uri);
      if (result != null) return result;
      if (attempt == 0) {
        AppLog.write('update check retry');
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    }
    AppLog.write('update check failed');
    return UpdateCheck.error;
  }

  /// One request. Null means "retry": only a network failure or a timeout is
  /// retried; an HTTP error is the server's answer and is final.
  static Future<UpdateCheck?> _request(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        AppLog.write('update check http ${response.statusCode}');
        return UpdateCheck.error;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) return UpdateCheck.error;
      }
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (value is! Map) return UpdateCheck.error;
      final info = UpdateInfo.parse(Map<String, dynamic>.from(value));
      AppLog.write(
        'update result: version=${info?.version ?? '-'} '
        'update_available=${value['update_available']} '
        'reason=${value['reason'] ?? '-'}',
      );
      if (info != null) debugPrint('update available: ${info.version}');
      return UpdateCheck(info: info);
    } on Object catch (error) {
      debugPrint('update check failed: $error');
      AppLog.write('update check failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the release (primary, then mirror), checks its SHA-256 and
  /// extracts it into a staging directory.
  static Future<UpdateStage> prepare(
    UpdateInfo info, {
    required void Function(int received, int total) onProgress,
  }) async {
    final sep = Platform.pathSeparator;
    final work = Directory(
      '${Directory.systemTemp.path}${sep}freeplayer-update-'
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    await work.create(recursive: true);
    final zip = File('${work.path}${sep}package.zip');

    var ok = false;
    for (final url in [info.downloadUrl, info.mirrorUrl]) {
      if (url.isEmpty) continue;
      try {
        await _download(
          url,
          zip,
          onProgress,
          maxBytes: info.size > 0 ? info.size : _maxPackageBytes,
        );
        ok = true;
        break;
      } on Object {
        ok = false;
      }
    }
    if (!ok) {
      await _cleanup(work);
      throw const UpdateException('下载失败，可到官网手动下载');
    }
    if (info.sha256.isNotEmpty) {
      final digest = await sha256.bind(zip.openRead()).first;
      if (digest.toString().toLowerCase() != info.sha256.toLowerCase()) {
        await _cleanup(work);
        throw const UpdateException('更新包校验失败，可到官网手动下载');
      }
    }

    // A release may be the Setup.exe itself. A verified installer needs no
    // extraction: it replaces the files and restarts the app on its own.
    if (await _isWindowsExecutable(zip)) {
      final installer = File('${work.path}${sep}setup.exe');
      await zip.rename(installer.path);
      return UpdateStage(
        sourceDir: '',
        workDir: work.path,
        installerPath: installer.path,
      );
    }

    final stage = Directory('${work.path}${sep}stage');
    await stage.create(recursive: true);
    try {
      await _extract(zip.path, stage.path);
    } on Object {
      await _cleanup(work);
      throw const UpdateException('更新包解压失败，可到官网手动下载');
    }
    return UpdateStage(sourceDir: _stageRoot(stage.path), workDir: work.path);
  }

  /// Starts update.exe from a temporary copy, so the executable inside the
  /// install directory can be replaced while it runs.
  static Future<void> launch(UpdateStage stage) async {
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (stage.isInstaller) {
      await _runInstaller(stage.installerPath, exeDir);
      return;
    }
    final candidates = [
      File('$exeDir${sep}update.exe'),
      File('$exeDir${sep}tools${sep}update.exe'),
    ];
    File? updater;
    for (final file in candidates) {
      if (file.existsSync()) {
        updater = file;
        break;
      }
    }
    if (updater == null) {
      throw const UpdateException('缺少 update.exe，请重新安装后再更新');
    }
    final local = File('${stage.workDir}${sep}update.exe');
    await updater.copy(local.path);
    await Process.start(
      local.path,
      [
        '--pid',
        '$pid',
        '--source',
        stage.sourceDir,
        '--target',
        exeDir,
        '--exe',
        'free_player.exe',
        '--restart',
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: stage.workDir,
    );
  }

  /// Runs the verified installer without any UI. It closes the running app
  /// itself (`CloseApplications=force` in the script) and starts the new build
  /// again after copying, so the caller just exits.
  static Future<void> _runInstaller(String path, String exeDir) async {
    // An install path with spaces does not survive the quoting of a detached
    // command line reliably; the installer remembers its previous folder
    // (UsePreviousAppDir), so only pass /DIR when it is unambiguous.
    final dir = exeDir.contains(' ') ? '' : '/DIR=$exeDir';
    final args = [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      if (dir.isNotEmpty) dir,
    ];
    AppLog.write('update: running installer $path');
    await Process.start(
      path,
      args,
      mode: ProcessStartMode.detached,
      workingDirectory: File(path).parent.path,
    );
  }

  static Future<bool> _isWindowsExecutable(File file) async {
    try {
      final handle = await file.open();
      try {
        final header = await handle.read(2);
        return header.length == 2 && header[0] == 0x4D && header[1] == 0x5A;
      } finally {
        await handle.close();
      }
    } on Object {
      return false;
    }
  }

  static Future<void> openManual(UpdateInfo info) async {
    final url = info.manualUrl.isNotEmpty ? info.manualUrl : info.downloadUrl;
    if (url.isEmpty) return;
    await Process.start(
      'cmd',
      ['/c', 'start', '', url],
      mode: ProcessStartMode.detached,
    );
  }

  /// A stalled or endless update host must not hang the app or fill the
  /// drive; every step is bounded.
  static const int _maxPackageBytes = 512 << 20;

  static Future<void> _download(
    String url,
    File target,
    void Function(int received, int total) onProgress, {
    int maxBytes = _maxPackageBytes,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
      final response =
          await request.close().timeout(const Duration(seconds: 25));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > maxBytes) {
            throw const HttpException('更新包超出预期大小');
          }
          sink.add(chunk);
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw const HttpException('incomplete download');
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _extract(String zipPath, String outDir) async {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input, verify: true);
      for (final entry in archive.files) {
        if (entry.isSymbolicLink) continue;
        final target = _safeTarget(outDir, entry.name);
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await File(target).parent.create(recursive: true);
        final output = OutputFileStream(target);
        entry.writeContent(output, freeMemory: false);
        output.close();
      }
    } finally {
      input.close();
    }
  }

  /// Rejects absolute paths, drive letters and `..` so a malicious archive
  /// cannot write outside the staging directory.
  static String _safeTarget(String root, String name) {
    final cleaned = name.replaceAll('\\', '/');
    if (cleaned.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(cleaned)) {
      throw const UpdateException('更新包路径非法');
    }
    final parts = <String>[];
    for (final part in cleaned.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') throw const UpdateException('更新包路径非法');
      parts.add(part);
    }
    if (parts.isEmpty) throw const UpdateException('更新包路径非法');
    return [root, ...parts].join(Platform.pathSeparator);
  }

  /// Releases usually wrap everything in one folder; accept both layouts.
  static String _stageRoot(String dir) {
    final sep = Platform.pathSeparator;
    if (File('$dir${sep}free_player.exe').existsSync()) return dir;
    for (final child in Directory(dir).listSync()) {
      if (child is Directory &&
          File('${child.path}${sep}free_player.exe').existsSync()) {
        return child.path;
      }
    }
    return dir;
  }

  static Future<void> _cleanup(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on Object {
      // A leftover temp folder is harmless.
    }
  }
}
