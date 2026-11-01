import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Small JSON-file store used for local state before SQLite is introduced.
/// Writes are atomic (temp file + rename) to survive a crash mid-write.
class LocalStore {
  LocalStore(this.file);

  final File file;
  Map<String, dynamic>? _cache;

  // Two saves can overlap (startup refresh + a user action). On Windows a
  // rename onto the destination fails while another handle is open, so all
  // saves queue behind one another.
  static Future<void> _writeQueue = Future<void>.value();

  Future<Map<String, dynamic>> read() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      if (!await file.exists()) return _cache = <String, dynamic>{};
      final text = await file.readAsString();
      if (text.trim().isEmpty) return _cache = <String, dynamic>{};
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return _cache = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } on FormatException {
      // A corrupt state file is replaced on next write; defaults are used now.
    } on FileSystemException {
      // Unreadable file: behave like an empty store.
    }
    return _cache = <String, dynamic>{};
  }

  Future<void> write(Map<String, dynamic> data) {
    _cache = data;
    final done = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _writeNow(data);
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> _writeNow(Map<String, dynamic> data) async {
    await file.parent.create(recursive: true);
    final tmp = File(
      '${file.path}.${pid}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(jsonEncode(data), flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // A reader can briefly hold the destination; retry before giving up.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await tmp.rename(file.path);
    }
  }
}
