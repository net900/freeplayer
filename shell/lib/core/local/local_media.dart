import 'dart:io';

import '../sp/models.dart';

const List<String> videoExtensions = [
  'mp4',
  'mkv',
  'mov',
  'avi',
  'flv',
  'ts',
  'webm',
  'm4v',
  'wmv',
];

/// Local files are represented with the same MediaPlan the player already
/// understands: source "local", no decryption (PRD §5.6).
abstract final class LocalMedia {
  static String? firstVideoPath(List<String> args) {
    for (final arg in args) {
      final candidate = arg.trim().replaceAll('"', '');
      if (candidate.isEmpty || candidate.startsWith('-')) continue;
      if (!_hasVideoExtension(candidate)) continue;
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Launch argument: a video file or a whole directory.
  static String? firstLaunchPath(List<String> args) {
    for (final arg in args) {
      final candidate = arg.trim().replaceAll('"', '');
      if (candidate.isEmpty || candidate.startsWith('-')) continue;
      if (File(candidate).existsSync()) {
        if (_hasVideoExtension(candidate)) return candidate;
      } else if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  /// Expands files and directories into one ordered play list. Directories are
  /// scanned recursively and sorted by natural file order (第2集 before 第10集).
  static List<String> collectVideos(List<String> paths) {
    final out = <String>[];
    final seen = <String>{};
    void take(String path) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        final entries = Directory(path).listSync(followLinks: false);
        for (final entry in entries) {
          take(entry.path);
        }
        return;
      }
      if (type != FileSystemEntityType.file) return;
      if (!_hasVideoExtension(path)) return;
      final normalized = File(path).absolute.path;
      if (!seen.add(normalized)) return;
      out.add(normalized);
    }

    for (final path in paths) {
      take(path);
    }
    out.sort(compareNatural);
    return out;
  }

  /// Natural sort: digit runs compare by value, everything else by code unit.
  static int compareNatural(String a, String b) {
    final ra = a.toLowerCase();
    final rb = b.toLowerCase();
    var i = 0;
    var j = 0;
    while (i < ra.length && j < rb.length) {
      final ca = ra.codeUnitAt(i);
      final cb = rb.codeUnitAt(j);
      final da = _isDigit(ca);
      final db = _isDigit(cb);
      if (da && db) {
        var ei = i;
        while (ei < ra.length && _isDigit(ra.codeUnitAt(ei))) {
          ei++;
        }
        var ej = j;
        while (ej < rb.length && _isDigit(rb.codeUnitAt(ej))) {
          ej++;
        }
        final na = int.tryParse(ra.substring(i, ei)) ?? 0;
        final nb = int.tryParse(rb.substring(j, ej)) ?? 0;
        if (na != nb) return na.compareTo(nb);
        i = ei;
        j = ej;
        continue;
      }
      if (ca != cb) return ca.compareTo(cb);
      i++;
      j++;
    }
    final rest = (ra.length - i).compareTo(rb.length - j);
    return rest != 0 ? rest : a.compareTo(b);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static MediaPlan buildPlan(String path) {
    final file = File(path);
    final uri = file.absolute.uri.toString();
    return MediaPlan(
      itemId: 'local:$path',
      episodeId: path,
      streams: [
        Stream(
          id: 'source',
          quality: 'source',
          url: uri,
          container: _extension(path),
          mimeType: mimeFor(path),
          extra: {'title': titleFor(path)},
        ),
      ],
      decryption: const DecryptionSpec(
        required: false,
        algorithm: 'none',
        location: 'server',
      ),
      extra: {'title': titleFor(path), 'local_path': path},
    );
  }

  static String titleFor(String path) {
    final name = File(path).uri.pathSegments.isEmpty
        ? path
        : File(path).uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String mimeFor(String path) {
    switch (_extension(path)) {
      case 'mkv':
        return 'video/x-matroska';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'flv':
        return 'video/x-flv';
      case 'ts':
        return 'video/mp2t';
      case 'webm':
        return 'video/webm';
      case 'wmv':
        return 'video/x-ms-wmv';
      default:
        return 'video/mp4';
    }
  }

  static bool _hasVideoExtension(String path) =>
      videoExtensions.contains(_extension(path));

  static String _extension(String path) {
    final name = File(path).uri.pathSegments.isEmpty
        ? path
        : File(path).uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}
