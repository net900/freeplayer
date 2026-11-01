import 'dart:io';

/// Registers `freeplayer://` for the current user, so the website can hand a
/// source to the app with one click. Failures stay silent: the site also
/// offers the address to paste manually.
///
/// Format: `freeplayer://source?url=<percent-encoded source url>`
Future<void> registerSourceUrlScheme() async {
  if (!Platform.isWindows) return;
  const key = r'HKCU\Software\Classes\freeplayer';
  final exe = Platform.resolvedExecutable;
  await _reg(['add', key, '/ve', '/d', 'URL:Free Player Source', '/f']);
  await _reg(['add', key, '/v', 'URL Protocol', '/d', '', '/f']);
  await _reg([
    'add',
    '$key\\shell\\open\\command',
    '/ve',
    '/d',
    '"$exe" "%1"',
    '/f',
  ]);
}

Future<void> _reg(List<String> args) async {
  try {
    await Process.run('reg', args, runInShell: true);
  } on Object {
    // A locked-down machine may refuse the write; adding a source by hand
    // still works.
  }
}
