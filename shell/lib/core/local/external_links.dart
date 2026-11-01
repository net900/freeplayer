import 'dart:io';

/// Opens a project link in the user's default browser. Failures are silent:
/// the address is also shown in the settings row so it can be copied.
Future<void> openExternalUrl(String url) async {
  if (!Platform.isWindows) return;
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  try {
    // `start` needs an empty window title before the URL.
    await Process.start(
      'cmd',
      ['/c', 'start', '', url],
      runInShell: true,
      mode: ProcessStartMode.detached,
    );
  } on Object {
    // No browser, or the shell refused; nothing useful to show.
  }
}
