import 'dart:io';

String joinPath(String a, String b) {
  if (a.isEmpty) return b;
  if (a.endsWith(Platform.pathSeparator)) return '$a$b';
  return '$a${Platform.pathSeparator}$b';
}

/// Application data lives under %APPDATA%\FreePlayer on Windows.
/// No third-party path package is used (PRD §17.3).
Directory appDataDirectory() {
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

/// DIY decryptors live next to the executable, as documented in PRD §7.3.
Directory decryptorsDirectory() {
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
  final profile = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return joinPath(joinPath(profile, 'Videos'), 'FreePlayer');
}
