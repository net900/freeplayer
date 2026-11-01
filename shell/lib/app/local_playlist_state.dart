import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/storage/local_store.dart';

/// The local files in the current playback session. The sidebar renders them
/// directly so a dropped folder becomes a file list, not a page. The list is
/// persisted so a restart keeps the files on the left.
class LocalPlaylistState extends ChangeNotifier {
  LocalPlaylistState({LocalStore? store}) : _store = store;

  final LocalStore? _store;
  Timer? _saveTimer;

  List<String> _files = const [];
  String _title = '';
  String _current = '';

  List<String> get files => _files;
  String get title => _title;
  String get current => _current;

  /// Restores the last session. Files that no longer exist are dropped.
  Future<void> load() async {
    final store = _store;
    if (store == null) return;
    try {
      final data = await store.read();
      final raw = data['files'];
      if (raw is! List) return;
      final files = raw
          .map((value) => value.toString())
          .where((path) => path.isNotEmpty && File(path).existsSync())
          .toList(growable: false);
      if (files.isEmpty) return;
      var current = data['current']?.toString() ?? '';
      if (!files.contains(current)) current = files.first;
      _files = List<String>.unmodifiable(files);
      _title = data['title']?.toString() ?? '';
      _current = current;
      notifyListeners();
    } on Object {
      // A corrupt list means an empty sidebar, never a failed startup.
    }
  }

  void setPlaylist(List<String> files, {String title = '', String current = ''}) {
    final nextCurrent = current.isNotEmpty
        ? current
        : (files.isNotEmpty ? files.first : '');
    if (listEquals(_files, files) &&
        _title == title &&
        _current == nextCurrent) {
      return;
    }
    _files = List<String>.unmodifiable(files);
    _title = title;
    _current = nextCurrent;
    _scheduleSave();
    notifyListeners();
  }

  void setCurrent(String path) {
    if (_current == path) return;
    _current = path;
    _scheduleSave();
    notifyListeners();
  }

  void clear() {
    if (_files.isEmpty && _current.isEmpty) return;
    _files = const [];
    _title = '';
    _current = '';
    _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    if (_store == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  void _save() {
    final store = _store;
    if (store == null) return;
    unawaited(
      store.write({
        'files': _files,
        'title': _title,
        'current': _current,
      }).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    final pending = _saveTimer;
    _saveTimer = null;
    if (pending != null && pending.isActive) {
      pending.cancel();
      _save();
    }
    super.dispose();
  }
}
