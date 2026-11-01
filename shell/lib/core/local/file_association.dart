import 'dart:io';

import 'local_media.dart';

/// Registers the app as a *candidate* video player. Windows 10/11 do not let an
/// application silently become the default handler; the user still confirms in
/// system settings (PRD §5.6). Everything here is user-scope (HKCU).
class FileAssociationService {
  static const String progId = 'FreePlayer.Video';
  static const String _classesRoot = r'HKCU\Software\Classes';

  Future<void> register() async {
    final exe = Platform.resolvedExecutable;
    await _reg([
      'add',
      '$_classesRoot\\$progId',
      '/ve',
      '/d',
      'Video file',
      '/f',
    ]);
    await _reg([
      'add',
      '$_classesRoot\\$progId\\shell\\open\\command',
      '/ve',
      '/d',
      '"$exe" "%1"',
      '/f',
    ]);
    for (final ext in videoExtensions) {
      await _reg([
        'add',
        '$_classesRoot\\.$ext\\OpenWithProgids',
        '/v',
        progId,
        '/t',
        'REG_NONE',
        '/d',
        '',
        '/f',
      ]);
    }
  }

  /// Opens a folder in the system file manager.
  Future<void> openFolder(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else {
        await Process.run('xdg-open', [dir.path]);
      }
    } on Object {
      // The shell is allowed to refuse; nothing else to do.
    }
  }

  Future<void> unregister() async {
    await _reg(['delete', '$_classesRoot\\$progId', '/f'], allowFailure: true);
    for (final ext in videoExtensions) {
      await _reg(
        [
          'delete',
          '$_classesRoot\\.$ext\\OpenWithProgids',
          '/v',
          progId,
          '/f',
        ],
        allowFailure: true,
      );
    }
  }

  Future<bool> isRegistered() async {
    final result = await Process.run(
      'reg.exe',
      ['query', '$_classesRoot\\$progId', '/ve'],
      runInShell: false,
    );
    return result.exitCode == 0;
  }

  /// Opens the Windows "Default apps" page so the user can finish the choice.
  Future<void> openSystemDefaultApps() async {
    await Process.run(
      'cmd.exe',
      ['/c', 'start', '', 'ms-settings:defaultapps'],
      runInShell: false,
    );
  }

  Future<void> _reg(List<String> args, {bool allowFailure = false}) async {
    final result = await Process.run('reg.exe', args, runInShell: false);
    if (result.exitCode != 0 && !allowFailure) {
      throw FileAssociationException(
        'reg.exe ${args.first} failed (${result.exitCode}): ${result.stderr}',
      );
    }
  }
}

class FileAssociationException implements Exception {
  FileAssociationException(this.message);

  final String message;

  @override
  String toString() => message;
}
