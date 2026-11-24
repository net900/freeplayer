import 'dart:io';

import 'package:path_provider/path_provider.dart' as provider;

import '../platform/platform.dart';

String joinPath(String a, String b) {
  if (a.isEmpty) return b;
  if (a.endsWith(Platform.pathSeparator)) return '$a$b';
  return '$a${Platform.pathSeparator}$b';
}

Directory? _appData;
String? _downloadRoot;

/// One-time directory setup. Windows resolves %APPDATA% synchronously; a
/// mobile sandbox has no such environment variable and is looked up through
/// the platform instead.
Future<void> initPlatformDirectories() async {
  if (!isMobilePlatform || _appData != null) return;
  Directory support;
  try {
    support = await provider.getApplicationSupportDirectory();
  } on Object {
    // A platform without the plugin still needs a writable home; the app
    // stays usable and only loses persistence between runs.
    support = Directory.systemTemp;
  }
  final dir = Directory(joinPath(support.path, 'FreePlayer'));
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } on Object {
    _appData = Directory.systemTemp;
    _downloadRoot = joinPath(Directory.systemTemp.path, 'Downloads');
    return;
  }
  _appData = dir;
  // App-specific external storage survives app updates and is reachable
  // without a storage permission. Downloads are kept there when available.
  String? external;
  if (Platform.isAndroid) {
    try {
      external = (await provider.getExternalStorageDirectory())?.path;
    } on Object {
      external = null;
    }
  }
  final root = external == null
      ? joinPath(dir.path, 'Downloads')
      : joinPath(external, 'Downloads');
  final downloads = Directory(root);
  try {
    if (!downloads.existsSync()) downloads.createSync(recursive: true);
    _downloadRoot = downloads.path;
  } on Object {
    final fallback = Directory(joinPath(dir.path, 'Downloads'));
    try {
      if (!fallback.existsSync()) fallback.createSync(recursive: true);
    } on Object {
      // defaultDownloadDirectory() will retry lazily.
    }
    _downloadRoot = fallback.path;
  }
}

/// Application data lives under %APPDATA%\FreePlayer on Windows and in the
/// app sandbox on Android. No third-party path package is used on desktop
/// (PRD §17.3); mobile has no synchronous native path source.
Directory appDataDirectory() {
  final resolved = _appData;
  if (resolved != null) return resolved;
  if (isMobilePlatform) {
    // initPlatformDirectories runs before bootstrap. This fallback keeps a
    // missed call from writing to the read-only filesystem root.
    final dir = Directory(joinPath(Directory.systemTemp.path, 'FreePlayer'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }
  final env = Platform.environment;
  final root = env['APPDATA'] ??
      env['LOCALAPPDATA'] ??
      Directory.current.path;
  final dir = Directory(joinPath(root, 'FreePlayer'));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}

File appDataFile(String name) => File(joinPath(appDataDirectory().path, name));

/// DIY decryptors live next to the executable on desktop (PRD §7.3). The
/// executable sits on a read-only partition on Android, so they live in the
/// app's data directory there and are downloaded by the source.
Directory decryptorsDirectory() {
  if (isMobilePlatform) {
    final dir = Directory(joinPath(appDataDirectory().path, 'decryptors'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return Directory(joinPath(exeDir, 'decryptors'));
}

/// Keeps a derived-artwork cache bounded. Everything in these folders can be
/// rebuilt from the source, so the oldest files are safe to drop.
void pruneCacheDirectory(Directory dir, {int maxFiles = 600}) {
  try {
    if (!dir.existsSync()) return;
    final files = dir.listSync().whereType<File>().toList();
    if (files.length <= maxFiles) return;
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final file in files.skip(maxFiles * 2 ~/ 3)) {
      try {
        file.deleteSync();
      } on Object {
        // Best effort.
      }
    }
  } on Object {
    // A cache that cannot be pruned still works.
  }
}

String defaultDownloadDirectory() {
  final mobile = _downloadRoot;
  if (mobile != null) return mobile;
  if (isMobilePlatform) {
    final dir = Directory(joinPath(appDataDirectory().path, 'Downloads'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }
  final profile = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return joinPath(joinPath(profile, 'Videos'), 'FreePlayer');
}
