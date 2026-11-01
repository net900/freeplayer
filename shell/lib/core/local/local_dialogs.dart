import 'dart:convert';
import 'dart:io';

/// Native open dialogs, taken from the Windows shell. The app ships for
/// Windows only, and doing it this way avoids a picker plugin whose
/// transitive `cross_file` version clashes with the drop target's.
abstract final class LocalDialogs {
  static Future<String?> pickFile() => _pick(_fileScript);

  static Future<String?> pickFolder() => _pick(_folderScript);

  static Future<String?> _pick(
    String Function(String outPath) build,
  ) async {
    if (!Platform.isWindows) return null;
    final out = File(
      '${Directory.systemTemp.path}\\free_player_pick_'
      '${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    final encoded = base64Encode(_utf16le(build(out.path)));
    try {
      final result = await Process.run(_powershell(), [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-EncodedCommand',
        encoded,
      ]);
      if (result.exitCode != 0 || !out.existsSync()) return null;
      final value = (await out.readAsString()).trim();
      return value.isEmpty ? null : value;
    } on Object {
      return null;
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  }

  /// A dev launch (and any shortcut with a trimmed PATH) may not resolve bare
  /// `powershell.exe`; the Windows directory always has it.
  static String _powershell() {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final full = '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    return File(full).existsSync() ? full : 'powershell.exe';
  }

  /// PowerShell's -EncodedCommand takes base64 of UTF-16LE, which also keeps
  /// the Chinese labels intact.
  static List<int> _utf16le(String value) {
    final bytes = <int>[];
    var i = 0;
    while (i < value.length) {
      final unit = value.codeUnitAt(i++);
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return bytes;
  }

  static String _fileScript(String outPath) => '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Title = '打开视频'
\$dialog.Filter = '视频文件|*.mp4;*.mkv;*.mov;*.avi;*.flv;*.ts;*.webm;*.m4v;*.wmv|所有文件|*.*'
\$dialog.Multiselect = \$false
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [System.IO.File]::WriteAllText('$outPath', \$dialog.FileName, [System.Text.Encoding]::UTF8)
}
''';

  static String _folderScript(String outPath) => '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '打开文件夹'
\$dialog.ShowNewFolderButton = \$false
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [System.IO.File]::WriteAllText('$outPath', \$dialog.SelectedPath, [System.Text.Encoding]::UTF8)
}
''';
}
