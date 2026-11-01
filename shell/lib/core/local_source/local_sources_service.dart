import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../app/app_controller.dart';
import '../gateway/models.dart';
import '../gateway/recommended_sources.dart';
import '../storage/local_store.dart';
import '../storage/paths.dart';
import 'local_js_source_api.dart';

class LocalSourceInstall {
  const LocalSourceInstall({
    required this.packageId,
    required this.sourceId,
    required this.name,
    required this.version,
    required this.filePath,
    required this.sha256,
    this.sourceUrl = '',
  });

  final String packageId;
  final String sourceId;
  final String name;
  final String version;
  final String filePath;
  final String sha256;

  /// Where this package was downloaded from, so every launch can re-check it.
  /// Empty for scripts pasted in or dropped into the directory by hand.
  final String sourceUrl;

  Map<String, dynamic> toJson() => {
        'package_id': packageId,
        'source_id': sourceId,
        'name': name,
        'version': version,
        'file': filePath,
        'sha256': sha256,
        'source_url': sourceUrl,
      };

  factory LocalSourceInstall.fromJson(Map<String, dynamic> json) {
    return LocalSourceInstall(
      packageId: json['package_id']?.toString() ?? '',
      sourceId: json['source_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      filePath: json['file']?.toString() ?? '',
      sha256: json['sha256']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
    );
  }

  LocalSourceInstall copyWith({String? sourceUrl}) => LocalSourceInstall(
        packageId: packageId,
        sourceId: sourceId,
        name: name,
        version: version,
        filePath: filePath,
        sha256: sha256,
        sourceUrl: sourceUrl ?? this.sourceUrl,
      );
}

/// Downloads, imports and restores local JS sources. Nothing is executed
/// outside the app process.
class LocalSourcesService {
  LocalSourcesService(this._store);

  final LocalStore _store;
  final Map<String, LocalSourceInstall> _installs = {};
  bool _legacyCleaned = false;

  Directory get directory =>
      Directory(joinPath(appDataDirectory().path, 'local_sources'));

  Future<void> load() async {
    final data = await _store.read();
    _legacyCleaned = data['legacy_removed'] == true;
    final raw = data['sources'];
    if (raw is! List) {
      if (!_legacyCleaned) {
        _legacyCleaned = true;
        await _save();
      }
      return;
    }
    for (final item in raw.whereType<Map>()) {
      final install = LocalSourceInstall.fromJson(
        Map<String, dynamic>.from(item),
      );
      if (install.packageId.isEmpty) continue;
      if (!_legacyCleaned && _isLegacy(install)) {
        try {
          final file = File(install.filePath);
          if (file.existsSync()) file.deleteSync();
        } on Object {
          // The install is removed from the list either way.
        }
        continue;
      }
      _installs[install.packageId] = install;
    }
    if (!_legacyCleaned) {
      _legacyCleaned = true;
      await _save();
    }
  }

  bool _isLegacy(LocalSourceInstall install) =>
      install.sourceId == 'dy555' ||
      install.name.contains('555') ||
      install.name.contains('红果');

  bool isInstalled(String packageId) =>
      _installs.containsKey(packageId) &&
      File(_installs[packageId]!.filePath).existsSync();

  String installedVersion(String packageId) =>
      _installs[packageId]?.version ?? '';

  String installedSha(String packageId) => _installs[packageId]?.sha256 ?? '';

  List<LocalSourceInstall> get installs =>
      _installs.values.toList(growable: false);

  /// The launch-time update check for one installed source.
  ///
  /// The remote file is the source of truth: the script is fetched again and
  /// compared by SHA-256, so no version bookkeeping is involved and a rebuilt
  /// file with the same version number still updates. A failed download, a
  /// broken script or a different source id leaves the working copy alone.
  ///
  /// Returns the display name when the package was replaced.
  Future<String?> refreshFromUrl(
    String packageId,
    String url,
    AppController controller,
  ) async {
    final install = _installs[packageId];
    if (install == null) return null;
    // A package whose file was deleted is repaired here as well: the install
    // record survives, so leaving it broken helps nobody.
    final installed = File(install.filePath).existsSync();
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = await _download(uri);
    } on Object {
      // Offline, or the host is down: keep what is installed.
      return null;
    }
    final digest = sha256.convert(bytes).toString();
    if (installed && digest == install.sha256.toLowerCase()) {
      // Same build. Remember the address so the next launch needs no catalog.
      await _adoptUrl(packageId, url);
      return null;
    }
    try {
      await _installBytes(
        bytes,
        controller,
        expectPackageId: packageId,
        sourceUrl: url,
        select: false,
      );
      return install.name;
    } on Object {
      return null;
    }
  }

  Future<void> _adoptUrl(String packageId, String url) async {
    final install = _installs[packageId];
    if (install == null || install.sourceUrl == url) return;
    _installs[packageId] = install.copyWith(sourceUrl: url);
    await _save();
  }

  Future<void> openDirectory() async {
    final dir = directory;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else {
        await Process.run('xdg-open', [dir.path]);
      }
    } on Object {
      // The path is shown in the dialog even if the file manager cannot open.
    }
  }

  Future<DiscoveredSource> install(
    RecommendedSource source,
    AppController controller, {
    bool select = true,
  }) async {
    if (!source.isLocal) {
      throw StateError('这不是本地源');
    }
    final uri = Uri.tryParse(source.packageUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('本地源包地址无效');
    }
    final bytes = await _download(uri);
    return _installBytes(
      bytes,
      controller,
      expectedSha: source.packageSha256,
      expectedSize: source.packageSize,
      displayName: source.name,
      packageVersion: source.packageVersion,
      select: select,
      sourceUrl: source.packageUrl,
    );
  }

  /// Reads a JS file from the web and installs it. This is the "enter a URL"
  /// path; the hash is recorded on first use.
  Future<DiscoveredSource> installFromUrl(
    String rawUrl,
    AppController controller,
  ) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('脚本地址需要以 http:// 或 https:// 开头');
    }
    return _installBytes(
      await _download(uri),
      controller,
      sourceUrl: uri.toString(),
    );
  }

  /// Installs script text pasted into the dialog.
  Future<DiscoveredSource> installScript(
    String script,
    AppController controller,
  ) async {
    if (script.trim().isEmpty) {
      throw StateError('脚本内容为空');
    }
    return _installBytes(Uint8List.fromList(utf8.encode(script)), controller);
  }

  /// Imports every `.js` file placed in the local source directory.
  Future<List<String>> scanDirectory(AppController controller) async {
    final dir = directory;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final imported = <String>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.js')) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('.') ||
          name.endsWith('.new') ||
          name.endsWith('.bak')) {
        continue;
      }
      try {
        final bytes = await entity.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        final known = _installs.values.where(
          (install) => install.filePath == entity.path,
        );
        if (known.isNotEmpty) {
          if (known.first.sha256 == digest) continue;
          // restore() already refused this file because its content no longer
          // matches the installed digest. Loading it here would execute the
          // tampered copy and silently re-pin it, so leave it out.
          continue;
        }
        final api = await LocalJsSourceApi.loadFile(entity.path);
        final id = api.manifest.id;
        if (id.isEmpty) {
          api.close();
          continue;
        }
        final existing = _installs[id];
        if (existing != null &&
            existing.filePath != entity.path &&
            File(existing.filePath).existsSync()) {
          // A working install already owns this source id; don't let an old
          // duplicate file silently replace it.
          api.close();
          continue;
        }
        await controller.registerLocalSource(
          packageId: id,
          name: api.manifest.name,
          api: api,
          ui: api.ui,
          manifest: api.manifest,
          select: imported.isEmpty && controller.activeSourceId.isEmpty,
        );
        _installs[id] = LocalSourceInstall(
          packageId: id,
          sourceId: api.manifest.id,
          name: api.manifest.name,
          version: api.manifest.version,
          filePath: entity.path,
          sha256: digest,
        );
        imported.add(api.manifest.name);
      } on Object {
        // Leave the file for the user to inspect or remove.
      }
    }
    if (imported.isNotEmpty) await _save();
    return imported;
  }

  Future<void> restore(AppController controller) async {
    for (final install in _installs.values.toList(growable: false)) {
      final file = File(install.filePath);
      if (!file.existsSync()) continue;
      try {
        if (install.sha256.isNotEmpty) {
          final digest = sha256.convert(await file.readAsBytes()).toString();
          if (digest != install.sha256) continue;
        }
        final api = await LocalJsSourceApi.loadFile(file.path);
        await controller.registerLocalSource(
          packageId: install.packageId,
          name: install.name,
          api: api,
          ui: api.ui,
          manifest: api.manifest,
          select: false,
        );
      } on Object {
        // A broken package stays on disk so the user can reinstall it.
      }
    }
    // Files copied into the directory by hand are picked up on launch.
    await scanDirectory(controller);
  }

  Future<void> remove(String packageId, AppController controller) async {
    final install = _installs.remove(packageId);
    await controller.removeGateway('local:$packageId');
    if (install != null) {
      final file = File(install.filePath);
      try {
        if (file.existsSync()) file.deleteSync();
      } on Object {
        // The source is already removed from the list.
      }
    }
    // Remove duplicate copies of the same source id as well, otherwise the
    // launch-time directory scan would bring a deleted source back.
    final dir = directory;
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.js')) {
          continue;
        }
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('.') || entity.path == install?.filePath) {
          continue;
        }
        try {
          final api = await LocalJsSourceApi.loadFile(entity.path);
          final same = api.manifest.id == packageId;
          api.close();
          if (same) entity.deleteSync();
        } on Object {
          // Leave unrelated or broken files alone.
        }
      }
    }
    await _save();
  }

  Future<Uint8List> _download(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final builder = await response
          .fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
        builder.add(chunk);
        return builder;
      }).timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('读取脚本失败：HTTP ${response.statusCode}');
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<DiscoveredSource> _installBytes(
    Uint8List bytes,
    AppController controller, {
    String? expectedSha,
    int expectedSize = 0,
    String? displayName,
    String? packageVersion,
    bool select = true,
    String sourceUrl = '',
    String expectPackageId = '',
  }) async {
    final digest = sha256.convert(bytes).toString();
    final expected = (expectedSha ?? '').toLowerCase();
    if (expected.isNotEmpty && digest != expected) {
      throw StateError('脚本校验失败，内容可能已损坏');
    }
    if (expectedSize > 0 && bytes.length != expectedSize) {
      throw StateError('脚本大小不一致');
    }

    final dir = directory;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final temp = File(
      joinPath(
        dir.path,
        '.import-${DateTime.now().microsecondsSinceEpoch}.js',
      ),
    );
    await temp.writeAsBytes(bytes, flush: true);

    LocalJsSourceApi? api;
    File? backup;
    File? installedFile;
    try {
      api = await LocalJsSourceApi.loadFile(temp.path);
      final id = api.manifest.id;
      if (id.isEmpty) {
        throw const FormatException('脚本缺少源 ID');
      }
      // A silent refresh may only replace the package it was asked about; a
      // different id at the same address is a new source, not an update.
      if (expectPackageId.isNotEmpty && id != expectPackageId) {
        throw const FormatException('脚本内容与已安装的源不匹配');
      }
      final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      installedFile = File(joinPath(dir.path, '$safeId.js'));
      if (installedFile.existsSync()) {
        backup = File('${installedFile.path}.bak');
        if (backup.existsSync()) backup.deleteSync();
        installedFile.renameSync(backup.path);
      }
      temp.renameSync(installedFile.path);

      final name = (displayName ?? '').trim().isEmpty
          ? api.manifest.name
          : displayName!.trim();
      final discovered = await controller.registerLocalSource(
        packageId: id,
        name: name,
        api: api,
        ui: api.ui,
        manifest: api.manifest,
        select: select,
      );
      _installs[id] = LocalSourceInstall(
        packageId: id,
        sourceId: api.manifest.id,
        name: name,
        version: (packageVersion ?? '').isNotEmpty
            ? packageVersion!
            : api.manifest.version,
        filePath: installedFile.path,
        sha256: digest,
        sourceUrl: sourceUrl,
      );
      await _save();
      if (backup != null && backup.existsSync()) backup.deleteSync();
      return discovered;
    } on Object {
      api?.close();
      try {
        if (temp.existsSync()) temp.deleteSync();
        if (backup != null && backup.existsSync()) {
          if (installedFile != null && installedFile.existsSync()) {
            installedFile.deleteSync();
          }
          backup.renameSync(installedFile!.path);
        } else if (installedFile != null && installedFile.existsSync()) {
          installedFile.deleteSync();
        }
      } on Object {
        // Keep the original error.
      }
      rethrow;
    }
  }

  Future<void> _save() async {
    await _store.write({
      'sources': _installs.values.map((item) => item.toJson()).toList(),
      'legacy_removed': _legacyCleaned,
    });
  }
}
