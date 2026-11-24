import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// SQLite storage for local playback state.
///
/// Windows ships `winsqlite3.dll`, so this binds the standard C API directly:
/// no extra package, no native binary to bundle. Every mutation touches one
/// row instead of re-encoding the whole `library.json`.
///
/// Returns plain JSON-shaped maps so this file does not depend on the
/// library models (and the library can keep its existing public API).
class LibraryDb {
  LibraryDb._(this._lib, this._db);

  final DynamicLibrary _lib;
  final Pointer<Void> _db;
  bool _closed = false;

  static const int _row = 100;
  static const int _done = 101;
  static const int _openReadWriteCreate = 0x00000002 | 0x00000004;
  static const int _null = 5;

  // Finalizers/pointers declared once; `sqlite3_bind_text` copies the string
  // when given SQLITE_TRANSIENT.
  static final Pointer<Void> _transient = Pointer<Void>.fromAddress(-1);

  /// Opens (or creates) the database. Returns null when the platform has no
  /// usable SQLite, so callers can keep the JSON fallback.
  static LibraryDb? open(String path) {
    if (!Platform.isWindows) return null;
    final lib = _openLibrary();
    if (lib == null) return null;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final filename = path.toNativeUtf8();
      final out = calloc<Pointer<Void>>();
      try {
        final db = lib.lookupFunction<_OpenNative, _OpenDart>(
          'sqlite3_open_v2',
        );
        final rc = db(filename, out, _openReadWriteCreate, nullptr);
        if (rc != 0 || out.value == nullptr) {
          if (out.value != nullptr) {
            _close(lib, out.value);
          }
          return null;
        }
        final instance = LibraryDb._(lib, out.value);
        instance._init();
        if (!instance._migrateJson(path)) {
          instance.close();
          return null;
        }
        return instance;
      } finally {
        calloc.free(filename);
        calloc.free(out);
      }
    } on Object catch (error) {
      debugPrint('library db open failed: $error');
      return null;
    }
  }

  static DynamicLibrary? _openLibrary() {
    // Prefer the OS copy so a stray DLL next to the app is never loaded.
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final full = '$root\\System32\\winsqlite3.dll';
    if (File(full).existsSync()) {
      try {
        return DynamicLibrary.open(full);
      } on Object {
        // Fall through to the loader search path.
      }
    }
    try {
      return DynamicLibrary.open('winsqlite3.dll');
    } on Object {
      return null;
    }
  }

  static void _close(DynamicLibrary lib, Pointer<Void> db) {
    try {
      lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close_v2')(db);
    } on Object {
      // Already closed.
    }
  }

  /// Releases the file handle. The app keeps one database for its lifetime;
  /// tests and future data-source switches need an explicit close.
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _exec('PRAGMA wal_checkpoint(TRUNCATE)');
    } on Object {
      // Best effort.
    }
    _close(_lib, _db);
  }

  void _init() {
    _exec('PRAGMA journal_mode=WAL');
    _exec('PRAGMA synchronous=NORMAL');
    _exec('''
CREATE TABLE IF NOT EXISTS history (
  series_key TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  cover TEXT NOT NULL DEFAULT '',
  source_id TEXT NOT NULL DEFAULT '',
  item_id TEXT NOT NULL DEFAULT '',
  episode_id TEXT NOT NULL DEFAULT '',
  episode_index INTEGER NOT NULL DEFAULT 0,
  position_sec INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT '',
  episode_count INTEGER NOT NULL DEFAULT 0,
  finished INTEGER NOT NULL DEFAULT 0,
  category TEXT NOT NULL DEFAULT ''
)''');
    _exec('''
CREATE TABLE IF NOT EXISTS episode_positions (
  series_key TEXT NOT NULL,
  episode_id TEXT NOT NULL,
  position_sec INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  completed INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (series_key, episode_id)
)''');
    _exec('''
CREATE TABLE IF NOT EXISTS favorites (
  series_key TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  cover TEXT NOT NULL DEFAULT '',
  source_id TEXT NOT NULL DEFAULT '',
  item_id TEXT NOT NULL DEFAULT '',
  episode_id TEXT NOT NULL DEFAULT '',
  episode_index INTEGER NOT NULL DEFAULT 0,
  position_sec INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT '',
  episode_count INTEGER NOT NULL DEFAULT 0,
  finished INTEGER NOT NULL DEFAULT 0,
  category TEXT NOT NULL DEFAULT ''
)''');
    _exec('''
CREATE TABLE IF NOT EXISTS downloads (
  asset_id TEXT PRIMARY KEY,
  series_key TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL DEFAULT '',
  bytes INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'queued',
  created_at TEXT NOT NULL DEFAULT '',
  episode_id TEXT NOT NULL DEFAULT '',
  episode_label TEXT NOT NULL DEFAULT '',
  quality TEXT NOT NULL DEFAULT '',
  cover TEXT NOT NULL DEFAULT '',
  episode_index INTEGER NOT NULL DEFAULT 0,
  segments_done INTEGER NOT NULL DEFAULT 0,
  segments_total INTEGER NOT NULL DEFAULT 0
)''');
    _exec(
      'CREATE TABLE IF NOT EXISTS hidden_favorites (series_key TEXT PRIMARY KEY)',
    );
    _exec(
      'CREATE TABLE IF NOT EXISTS hidden_history (series_key TEXT PRIMARY KEY)',
    );
    _exec(
      'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT \'\')',
    );
  }

  /// Imports the old single-file state once and keeps the file as a backup.
  /// Returns false when the import failed, so the caller can keep using the
  /// JSON store for this session instead of showing an empty library.
  bool _migrateJson(String dbPath) {
    final done = _query("SELECT value FROM meta WHERE key = 'migrated'");
    if (done.isNotEmpty) return true;
    final jsonPath = dbPath.endsWith('.db')
        ? '${dbPath.substring(0, dbPath.length - 3)}.json'
        : '$dbPath.json';
    final file = File(jsonPath);
    if (file.existsSync()) {
      try {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is Map) {
          _transaction(() {
            for (final row in _list(raw['history'])) {
              _writeHistory('history', _map(row));
            }
            for (final row in _list(raw['favorites'])) {
              _writeHistory('favorites', _map(row));
            }
            final positions = _map(raw['episode_positions']);
            positions.forEach((key, value) {
              final parts = key.split('|');
              if (parts.length < 2) return;
              final row = _map(value);
              _writePosition(
                parts[0],
                parts.sublist(1).join('|'),
                _int(row['position_sec']),
                _int(row['duration_sec']),
                completed: false,
                updatedAt: _str(row['updated_at']),
              );
            });
            for (final row in _list(raw['downloads'])) {
              _writeDownload(_map(row));
            }
            for (final key in _list(raw['hidden_favorites'])) {
              _exec(
                'INSERT OR IGNORE INTO hidden_favorites(series_key) VALUES(?)',
                [_str(key)],
              );
            }
            for (final key in _list(raw['hidden_history'])) {
              _exec(
                'INSERT OR IGNORE INTO hidden_history(series_key) VALUES(?)',
                [_str(key)],
              );
            }
            final rate = raw['playback_rate'];
            if (rate is num) {
              _setMeta('playback_rate', '$rate');
            }
          });
        }
        _setMeta('migrated', '1');
        return true;
      } on Object catch (error) {
        // Do not mark the migration as done: the next launch retries, and
        // this session keeps reading the JSON file.
        debugPrint('library db migration skipped: $error');
        return false;
      }
    }
    _setMeta('migrated', '1');
    return true;
  }

  // ------------------------------------------------------------- reads

  List<Map<String, dynamic>> history() =>
      _query('SELECT * FROM history ORDER BY rowid DESC');

  List<Map<String, dynamic>> favorites() =>
      _query('SELECT * FROM favorites ORDER BY rowid DESC');

  List<Map<String, dynamic>> downloads() =>
      _query('SELECT * FROM downloads ORDER BY rowid DESC');

  Map<String, int> episodePositions(String seriesKey) {
    final rows = _query(
      'SELECT episode_id, position_sec, duration_sec, completed '
      'FROM episode_positions WHERE series_key = ?',
      [seriesKey],
    );
    final out = <String, int>{};
    for (final row in rows) {
      final position = _int(row['position_sec']);
      final duration = _int(row['duration_sec']);
      // A finished episode has no resume point, but it still counts as
      // watched in the episode drawer.
      if (position > 0) {
        out[_str(row['episode_id'])] = position;
      } else if (_int(row['completed']) == 1) {
        out[_str(row['episode_id'])] = duration > 0 ? duration : 6;
      }
    }
    return out;
  }

  Map<String, ({int position, int duration})> episodeProgress() {
    final rows = _query(
      'SELECT series_key, episode_id, position_sec, duration_sec '
      'FROM episode_positions',
    );
    final out = <String, ({int position, int duration})>{};
    for (final row in rows) {
      final position = _int(row['position_sec']);
      final duration = _int(row['duration_sec']);
      if (position <= 0 || duration <= 0) continue;
      out['${_str(row['series_key'])}|${_str(row['episode_id'])}'] =
          (position: position, duration: duration);
    }
    return out;
  }

  /// Resume seconds for one episode. A finished row (or one saved at the
  /// very end) restarts from zero.
  int episodeResume(String seriesKey, String episodeId) {
    final rows = _query(
      'SELECT position_sec, duration_sec, completed FROM episode_positions '
      'WHERE series_key = ? AND episode_id = ? LIMIT 1',
      [seriesKey, episodeId],
    );
    if (rows.isEmpty) return 0;
    final row = rows.first;
    if (_int(row['completed']) == 1) return 0;
    final position = _int(row['position_sec']);
    final duration = _int(row['duration_sec']);
    if (position <= 0) return 0;
    if (duration > 0 && position >= duration - 5) return 0;
    return position;
  }

  double playbackRate() {
    final rows = _query("SELECT value FROM meta WHERE key = 'playback_rate'");
    if (rows.isEmpty) return 1.0;
    final value = double.tryParse(_str(rows.first['value']));
    if (value == null || value < 0.25 || value > 4) return 1.0;
    return value;
  }

  Set<String> hiddenFavorites() => _hidden('hidden_favorites');

  Set<String> hiddenHistory() => _hidden('hidden_history');

  Set<String> _hidden(String table) {
    final rows = _query('SELECT series_key FROM $table');
    return {
      for (final row in rows)
        if (_str(row['series_key']).isNotEmpty) _str(row['series_key']),
    };
  }

  // ------------------------------------------------------------- writes

  void recordProgress(Map<String, dynamic> record) {
    _transaction(() {
      _writeHistory('history', record);
      _exec(
        'DELETE FROM hidden_history WHERE series_key = ?',
        [_str(record['series_key'])],
      );
    });
  }

  void recordEpisodePosition(
    String seriesKey,
    String episodeId, {
    required int positionSec,
    required int durationSec,
    bool completed = false,
  }) {
    _writePosition(
      seriesKey,
      episodeId,
      positionSec,
      durationSec,
      completed: completed,
      updatedAt: DateTime.now().toIso8601String(),
    );
    _prunePositions();
  }

  /// One transaction for a progress tick: history row plus the resume point.
  void recordPlayback(
    Map<String, dynamic> record, {
    required int resumePositionSec,
    required int resumeDurationSec,
    required bool completed,
  }) {
    final seriesKey = _str(record['series_key']);
    final episodeId = _str(record['episode_id']);
    _transaction(() {
      _writeHistory('history', record);
      _exec(
        'DELETE FROM hidden_history WHERE series_key = ?',
        [seriesKey],
      );
      if (episodeId.isNotEmpty) {
        _writePosition(
          seriesKey,
          episodeId,
          resumePositionSec,
          resumeDurationSec,
          completed: completed,
          updatedAt: _str(record['updated_at']),
        );
      }
    });
    _prunePositions();
  }

  void setPlaybackRate(double rate) => _setMeta('playback_rate', '$rate');

  void toggleFavorite(Map<String, dynamic> record) {
    final key = _str(record['series_key']);
    if (key.isEmpty) return;
    final exists = _query('SELECT 1 FROM favorites WHERE series_key = ?', [key])
        .isNotEmpty;
    _transaction(() {
      if (exists) {
        _exec('DELETE FROM favorites WHERE series_key = ?', [key]);
      } else {
        _writeHistory('favorites', record);
        _exec('DELETE FROM hidden_favorites WHERE series_key = ?', [key]);
      }
    });
  }

  bool isFavorite(String seriesKey) =>
      _query('SELECT 1 FROM favorites WHERE series_key = ?', [seriesKey])
          .isNotEmpty;

  void removeFavorites(Set<String> keys) {
    if (keys.isEmpty) return;
    _transaction(() {
      for (final key in keys) {
        _exec('DELETE FROM favorites WHERE series_key = ?', [key]);
        _exec(
          'INSERT OR IGNORE INTO hidden_favorites(series_key) VALUES(?)',
          [key],
        );
      }
    });
  }

  void removeHistory(Set<String> keys) {
    if (keys.isEmpty) return;
    _transaction(() {
      for (final key in keys) {
        _exec('DELETE FROM history WHERE series_key = ?', [key]);
        _exec(
          'INSERT OR IGNORE INTO hidden_history(series_key) VALUES(?)',
          [key],
        );
      }
    });
  }

  void addDownload(Map<String, dynamic> record) {
    _writeDownload(record);
  }

  void removeDownload(String assetId) {
    _exec('DELETE FROM downloads WHERE asset_id = ?', [assetId]);
  }

  void _writeHistory(String table, Map<String, dynamic> record) {
    _exec(
      'INSERT OR REPLACE INTO $table ('
      'series_key,title,cover,source_id,item_id,episode_id,episode_index,'
      'position_sec,duration_sec,updated_at,episode_count,finished,category'
      ') VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        _str(record['series_key']),
        _str(record['title']),
        _str(record['cover']),
        _str(record['source_id']),
        _str(record['item_id']),
        _str(record['episode_id']),
        _int(record['episode_index']),
        _int(record['position_sec']),
        _int(record['duration_sec']),
        _str(record['updated_at']),
        _int(record['episode_count']),
        record['finished'] == true ? 1 : 0,
        _str(record['category']),
      ],
    );
  }

  void _writePosition(
    String seriesKey,
    String episodeId,
    int positionSec,
    int durationSec, {
    required bool completed,
    required String updatedAt,
  }) {
    _exec(
      'INSERT OR REPLACE INTO episode_positions ('
      'series_key,episode_id,position_sec,duration_sec,completed,updated_at'
      ') VALUES(?,?,?,?,?,?)',
      [
        seriesKey,
        episodeId,
        positionSec,
        durationSec,
        completed ? 1 : 0,
        updatedAt,
      ],
    );
  }

  void _prunePositions() {
    _exec(
      'DELETE FROM episode_positions WHERE rowid NOT IN ('
      'SELECT rowid FROM episode_positions ORDER BY updated_at DESC LIMIT 300'
      ')',
    );
  }

  void _writeDownload(Map<String, dynamic> record) {
    _exec(
      'INSERT OR REPLACE INTO downloads ('
      'asset_id,series_key,title,path,bytes,state,created_at,episode_id,'
      'episode_label,quality,cover,episode_index,segments_done,segments_total'
      ') VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        _str(record['asset_id']),
        _str(record['series_key']),
        _str(record['title']),
        _str(record['path']),
        _int(record['bytes']),
        _str(record['state']),
        _str(record['created_at']),
        _str(record['episode_id']),
        _str(record['episode_label']),
        _str(record['quality']),
        _str(record['cover']),
        _int(record['episode_index']),
        _int(record['segments_done']),
        _int(record['segments_total']),
      ],
    );
  }

  void _setMeta(String key, String value) {
    _exec(
      'INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
      [key, value],
    );
  }

  // ------------------------------------------------------------- SQLite

  void _exec(String sql, [List<Object?> params = const []]) {
    final statement = _prepare(sql);
    try {
      _bind(statement, params);
      while (true) {
        final rc = _stepFn(statement);
        if (rc == _done) break;
        if (rc != _row) {
          throw StateError(_error());
        }
      }
    } finally {
      _finalize(statement);
    }
  }

  List<Map<String, dynamic>> _query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final statement = _prepare(sql);
    final out = <Map<String, dynamic>>[];
    try {
      _bind(statement, params);
      final columns = _columnCount(statement);
      final names = <String>[
        for (var i = 0; i < columns; i++) _columnName(statement, i),
      ];
      while (true) {
        final rc = _step(statement);
        if (rc == _done) break;
        if (rc != _row) throw StateError(_error());
        final row = <String, dynamic>{};
        for (var i = 0; i < columns; i++) {
          row[names[i]] = _columnValue(statement, i);
        }
        out.add(row);
      }
    } finally {
      _finalize(statement);
    }
    return out;
  }

  void _transaction(void Function() body) {
    _exec('BEGIN IMMEDIATE');
    try {
      body();
      _exec('COMMIT');
    } on Object {
      try {
        _exec('ROLLBACK');
      } on Object {
        // The original error is more useful.
      }
      rethrow;
    }
  }

  Pointer<Void> _prepare(String sql) {
    final text = sql.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final rc = _prepareFn(_db, text, -1, out, nullptr);
      if (rc != 0) throw StateError(_error());
      return out.value;
    } finally {
      calloc.free(text);
      calloc.free(out);
    }
  }

  void _bind(Pointer<Void> statement, List<Object?> params) {
    for (var i = 0; i < params.length; i++) {
      final value = params[i];
      final index = i + 1;
      if (value == null) {
        _bindNull(statement, index);
      } else if (value is int) {
        _bindInt(statement, index, value);
      } else if (value is double) {
        _bindDouble(statement, index, value);
      } else {
        final text = '$value'.toNativeUtf8();
        try {
          // -1 lets SQLite read the NUL-terminated string; SQLITE_TRANSIENT
          // makes it copy the bytes before we free them.
          _bindText(statement, index, text, -1, _transient);
        } finally {
          calloc.free(text);
        }
      }
    }
  }

  Object? _columnValue(Pointer<Void> statement, int index) {
    switch (_columnType(statement, index)) {
      case _null:
        return null;
      case 1: // INTEGER
        return _columnInt(statement, index);
      case 2: // FLOAT
        return _columnDouble(statement, index);
      default:
        final pointer = _columnText(statement, index);
        if (pointer == nullptr) return null;
        return pointer.toDartString(length: _columnBytes(statement, index));
    }
  }

  String _columnName(Pointer<Void> statement, int index) =>
      _columnNameFn(statement, index).toDartString();

  String _error() {
    try {
      return _errorFn(_db).toDartString();
    } on Object {
      return 'sqlite error';
    }
  }

  int _step(Pointer<Void> statement) => _stepFn(statement);

  void _finalize(Pointer<Void> statement) {
    _finalizeFn(statement);
  }

  // Bound functions, resolved lazily once.
  late final _PrepareDart _prepareFn =
      _lib.lookupFunction<_PrepareNative, _PrepareDart>('sqlite3_prepare_v2');
  late final _StepDart _stepFn =
      _lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step');
  late final _FinalizeDart _finalizeFn =
      _lib.lookupFunction<_FinalizeNative, _FinalizeDart>('sqlite3_finalize');
  late final _BindTextDart _bindText =
      _lib.lookupFunction<_BindTextNative, _BindTextDart>('sqlite3_bind_text');
  late final _BindIntDart _bindInt =
      _lib.lookupFunction<_BindIntNative, _BindIntDart>('sqlite3_bind_int64');
  late final _BindDoubleDart _bindDouble =
      _lib.lookupFunction<_BindDoubleNative, _BindDoubleDart>(
          'sqlite3_bind_double');
  late final _BindNullDart _bindNull =
      _lib.lookupFunction<_BindNullNative, _BindNullDart>('sqlite3_bind_null');
  late final _ColumnCountDart _columnCount =
      _lib.lookupFunction<_ColumnCountNative, _ColumnCountDart>(
    'sqlite3_column_count',
  );
  late final _ColumnNameDart _columnNameFn =
      _lib.lookupFunction<_ColumnNameNative, _ColumnNameDart>(
    'sqlite3_column_name',
  );
  late final _ColumnTypeDart _columnType =
      _lib.lookupFunction<_ColumnTypeNative, _ColumnTypeDart>(
    'sqlite3_column_type',
  );
  late final _ColumnIntDart _columnInt =
      _lib.lookupFunction<_ColumnIntNative, _ColumnIntDart>(
    'sqlite3_column_int64',
  );
  late final _ColumnDoubleDart _columnDouble =
      _lib.lookupFunction<_ColumnDoubleNative, _ColumnDoubleDart>(
    'sqlite3_column_double',
  );
  late final _ColumnTextDart _columnText =
      _lib.lookupFunction<_ColumnTextNative, _ColumnTextDart>(
    'sqlite3_column_text',
  );
  late final _ColumnBytesDart _columnBytes =
      _lib.lookupFunction<_ColumnBytesNative, _ColumnBytesDart>(
    'sqlite3_column_bytes',
  );
  late final _ErrorDart _errorFn =
      _lib.lookupFunction<_ErrorNative, _ErrorDart>('sqlite3_errmsg');
}

// ---------------------------------------------------------------- FFI types

typedef _OpenNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Pointer<Void>>,
  Int32,
  Pointer<Utf8>,
);
typedef _OpenDart = int Function(
  Pointer<Utf8>,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Utf8>,
);

typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);

typedef _PrepareNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Utf8>>,
);
typedef _PrepareDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Utf8>>,
);

typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);

typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);

typedef _BindTextNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf8>,
  Int32,
  Pointer<Void>,
);
typedef _BindTextDart = int Function(
  Pointer<Void>,
  int,
  Pointer<Utf8>,
  int,
  Pointer<Void>,
);

typedef _BindIntNative = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindIntDart = int Function(Pointer<Void>, int, int);

typedef _BindDoubleNative = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);

typedef _BindNullNative = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);

typedef _ColumnCountNative = Int32 Function(Pointer<Void>);
typedef _ColumnCountDart = int Function(Pointer<Void>);

typedef _ColumnNameNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColumnNameDart = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _ColumnTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColumnTypeDart = int Function(Pointer<Void>, int);

typedef _ColumnIntNative = Int64 Function(Pointer<Void>, Int32);
typedef _ColumnIntDart = int Function(Pointer<Void>, int);

typedef _ColumnDoubleNative = Double Function(Pointer<Void>, Int32);
typedef _ColumnDoubleDart = double Function(Pointer<Void>, int);

typedef _ColumnTextNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColumnTextDart = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _ColumnBytesNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColumnBytesDart = int Function(Pointer<Void>, int);

typedef _ErrorNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrorDart = Pointer<Utf8> Function(Pointer<Void>);

// ---------------------------------------------------------------- helpers

Map<String, dynamic> _map(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

List<Object?> _list(Object? value) => value is List ? value : const [];

String _str(Object? value) => value == null ? '' : '$value';

int _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? 0;
}
