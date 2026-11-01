import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sp/models.dart';
import '../storage/paths.dart';

enum DecryptorKind { descriptor, wasm, native }

class DecryptorEntry {
  const DecryptorEntry({
    required this.id,
    required this.path,
    required this.kind,
    required this.bytes,
    required this.modifiedAt,
    this.version = '',
    this.sha256 = '',
  });

  final String id;
  final String path;
  final DecryptorKind kind;
  final int bytes;
  final DateTime modifiedAt;
  final String version;
  final String sha256;
}

/// Lists DIY decryptors from the local directory and installs hash-pinned
/// modules declared by a source.
///
/// A downloadable module is only accepted when its SHA-256 matches the value
/// in the source manifest. Installed files are never executed by this class;
/// the local core decides when to load them.
class DecryptorRegistry {
  DecryptorRegistry({Directory? directory})
      : directory = directory ?? decryptorsDirectory();

  final Directory directory;

  Future<List<DecryptorEntry>> scan() async {
    if (!await directory.exists()) return const [];
    final entries = <DecryptorEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final kind = _kindOf(entity.path);
      if (kind == null) continue;
      final stat = await entity.stat();
      final name = entity.uri.pathSegments.last;
      entries.add(DecryptorEntry(
        id: name.split('.').first,
        path: entity.path,
        kind: kind,
        bytes: stat.size,
        modifiedAt: stat.modified,
      ));
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return entries;
  }

  /// Downloads and verifies one module. Returns the installed file, or null
  /// when the spec is built-in, malformed, unreachable or fails verification.
  Future<File?> ensure(DecryptorSpec spec) async {
    if (!spec.downloadable || !_matchesPlatform(spec)) return null;
    final uri = Uri.tryParse(spec.url);
    if (uri == null || !_allowed(uri)) return null;

    final version = _safe(spec.version.isEmpty ? 'latest' : spec.version);
    final dir = Directory(joinPath(joinPath(directory.path, _safe(spec.id)), version));
    final marker = File('${dir.path}.remove');
    if (await marker.exists()) {
      var cleared = false;
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        cleared = true;
      } on Object {
        // Still loaded from the previous run.
      }
      if (cleared) {
        try {
          await marker.delete();
        } on Object {
          // Best effort.
        }
      }
    }
    await dir.create(recursive: true);

    final target = File(joinPath(dir.path, _fileName(spec, uri)));
    final descriptor = File(joinPath(dir.path, '${_safe(spec.id)}.json'));

    if (await target.exists()) {
      final digest = await _sha256Of(target);
      if (digest == spec.sha256) {
        // Re-using the module cancels a deletion left from removing its
        // source while the DLL was loaded.
        if (await marker.exists()) {
          try {
            await marker.delete();
          } on Object {
            // Best effort.
          }
        }
        await _writeDescriptor(descriptor, spec, target);
        return target;
      }
    }

    final temp = File('${target.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri).timeout(
            const Duration(seconds: 30),
          );
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close().timeout(
            const Duration(seconds: 60),
          );
      if (response.statusCode != HttpStatus.ok) return null;

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        builder.add(chunk);
        if (builder.length > 64 * 1024 * 1024) return null;
      }
      final bytes = builder.takeBytes();
      if (spec.size > 0 && bytes.length != spec.size) return null;
      if (sha256.convert(bytes).toString() != spec.sha256) return null;

      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      await _writeDescriptor(descriptor, spec, target);
      return target;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
      try {
        if (await temp.exists()) await temp.delete();
      } on Object {
        // Best effort cleanup.
      }
    }
  }

  Future<void> ensureAll(Iterable<DecryptorSpec> specs) async {
    for (final spec in specs) {
      if (!spec.downloadable) continue;
      await ensure(spec);
    }
  }

  /// Removes the modules a deleted source installed. A DLL that is currently
  /// loaded cannot be removed on Windows; that version is marked and cleaned
  /// up on the next launch, before anything loads it.
  Future<void> removeAll(Iterable<DecryptorSpec> specs) async {
    final touchedIds = <String>{};
    for (final spec in specs) {
      if (!spec.downloadable || spec.id.isEmpty) continue;
      final id = _safe(spec.id);
      final version = _safe(spec.version.isEmpty ? 'latest' : spec.version);
      final idDir = Directory(joinPath(directory.path, id));
      final versionDir = Directory(joinPath(idDir.path, version));
      touchedIds.add(idDir.path);
      try {
        if (await versionDir.exists()) {
          await versionDir.delete(recursive: true);
        }
      } on Object {
        // Finish next launch.
      }
      if (await versionDir.exists()) {
        try {
          await File('${versionDir.path}.remove').writeAsString('');
        } on Object {
          // Nothing else can be done now.
        }
      }
    }
    for (final path in touchedIds) {
      try {
        final idDir = Directory(path);
        if (await idDir.exists() && await idDir.list().isEmpty) {
          await idDir.delete();
        }
      } on Object {
        // Best effort.
      }
    }
  }

  /// Deletes modules whose source was removed while their DLL was loaded.
  Future<void> cleanupPendingRemoval() async {
    if (!await directory.exists()) return;
    try {
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.remove')) continue;
        final targetPath =
            entity.path.substring(0, entity.path.length - '.remove'.length);
        try {
          final target = Directory(targetPath);
          if (await target.exists()) await target.delete(recursive: true);
          await entity.delete();
        } on Object {
          // Still loaded; try again next launch.
        }
      }
    } on Object {
      // A missing or unreadable directory is harmless.
    }
  }

  DecryptorKind? _kindOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.json')) return DecryptorKind.descriptor;
    if (lower.endsWith('.wasm')) return DecryptorKind.wasm;
    if (lower.endsWith('.dll') ||
        lower.endsWith('.so') ||
        lower.endsWith('.dylib')) {
      return DecryptorKind.native;
    }
    return null;
  }

  bool _matchesPlatform(DecryptorSpec spec) {
    final os = spec.os.toLowerCase();
    if (os.isNotEmpty) {
      final current = Platform.isWindows
          ? 'windows'
          : Platform.isLinux
              ? 'linux'
              : Platform.isMacOS
                  ? 'macos'
                  : '';
      final osMatches = current == os || (current == 'macos' && os == 'darwin');
      if (!osMatches) return false;
    }
    final arch = spec.arch.toLowerCase();
    if (arch.isNotEmpty) {
      final abi = Abi.current().toString().toLowerCase();
      final matches = (arch == 'x86_64' &&
              (abi.contains('x64') || abi.contains('x86_64'))) ||
          (arch == 'arm64' &&
              (abi.contains('arm64') || abi.contains('aarch64')));
      if (!matches) return false;
    }
    return true;
  }

  bool _allowed(Uri uri) {
    // HTTP is supported for self-hosted/LAN sources. Public deployments
    // should use HTTPS; the SHA-256 check still rejects corrupted files, but
    // only a trusted manifest protects against a tampered hash.
    return uri.scheme == 'https' || uri.scheme == 'http';
  }

  String _fileName(DecryptorSpec spec, Uri uri) {
    if (spec.file.isNotEmpty) return _safe(spec.file);
    final segments = uri.pathSegments;
    final raw = segments.isEmpty ? '' : segments.last;
    if (raw.isNotEmpty && raw.contains('.')) return _safe(raw);
    final ext = switch (spec.os.toLowerCase()) {
      'windows' => 'dll',
      'linux' => 'so',
      'macos' || 'darwin' => 'dylib',
      _ => 'dll',
    };
    return 'fp_decryptor_${_safe(spec.id)}.$ext';
  }

  String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<String> _sha256Of(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _writeDescriptor(
    File file,
    DecryptorSpec spec,
    File target,
  ) async {
    final payload = {
      'id': spec.id,
      'version': spec.version,
      'url': spec.url,
      'sha256': spec.sha256,
      'size': spec.size,
      'file': spec.file,
      'algorithms': spec.algorithms,
      'abi': spec.abi,
      'path': target.path,
    };
    await file.writeAsString(jsonEncode(payload), flush: true);
  }
}
