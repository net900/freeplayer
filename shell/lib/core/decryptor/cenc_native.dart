import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../storage/paths.dart';

typedef _CreateNative = Pointer<Void> Function(
  Pointer<Uint8>,
  Int32,
  Int64,
  Int64,
);
typedef _CreateDart = Pointer<Void> Function(Pointer<Uint8>, int, int, int);
typedef _SpanNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Int64,
  Pointer<Int64>,
  Pointer<Int64>,
);
typedef _SpanDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Int64>,
  Pointer<Int64>,
);
typedef _DecryptNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Int32,
  Int64,
);
typedef _DecryptDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _IndexInt64Native = Int64 Function(Pointer<Void>);
typedef _IndexInt64Dart = int Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ErrorNative = Pointer<Utf8> Function();

/// One parsed MP4 CENC index. Holds native memory until disposed.
class CencIndex {
  CencIndex._(this._native, this._handle, this.size, this.moovEnd);

  final CencNative _native;
  final Pointer<Void> _handle;
  final int size;
  final int moovEnd;
  bool _disposed = false;

  /// Widens a byte range to sample edges (AES-CTR cannot decrypt a partial
  /// sample on its own).
  ({int start, int end}) span(int start, int end) {
    final out = calloc<Int64>(2);
    try {
      _native._span(_handle, start, end, out, out + 1);
      return (start: out[0], end: out[1]);
    } finally {
      calloc.free(out);
    }
  }

  /// Decrypts [data], which starts at absolute offset [start]. Returns an
  /// empty array when the native call fails.
  Uint8List decrypt(Uint8List data, int start, Uint8List key) {
    if (_disposed || data.isEmpty) return Uint8List(0);
    final dataPointer = malloc.allocate<Uint8>(data.length);
    final keyPointer = malloc.allocate<Uint8>(key.length);
    try {
      dataPointer.asTypedList(data.length).setAll(0, data);
      keyPointer.asTypedList(key.length).setAll(0, key);
      final result = _native._decrypt(
        _handle,
        keyPointer,
        key.length,
        dataPointer,
        data.length,
        start,
      );
      if (result != 0) return Uint8List(0);
      return Uint8List.fromList(dataPointer.asTypedList(data.length));
    } finally {
      malloc.free(dataPointer);
      malloc.free(keyPointer);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native._free(_handle);
  }
}

/// FFI binding for decryptors\cenc_decrypt.dll. The library only decrypts
/// CENC-AES-CTR and parses the MP4 index; keys and streams come from the API.
class CencNative {
  CencNative._(
    this._create,
    this._span,
    this._decrypt,
    this._size,
    this._moovEnd,
    this._free,
    this._error,
  );

  final _CreateDart _create;
  final _SpanDart _span;
  final _DecryptDart _decrypt;
  final _IndexInt64Dart _size;
  final _IndexInt64Dart _moovEnd;
  final _FreeDart _free;
  final _ErrorNative _error;

  static CencNative? _instance;

  static const String libraryName = String.fromEnvironment(
    'FREEPLAYER_CENC_DLL',
    defaultValue: 'cenc_decrypt.dll',
  );

  /// The source core carries the same fp_cenc_* exports, so a single file
  /// serves both roles and only one download is needed.
  static const String coreLibraryName = String.fromEnvironment(
    'FREEPLAYER_CORE_DLL',
    defaultValue: 'freeplayer_core.dll',
  );

  /// Loads the library on first use; null when neither file is available.
  static CencNative? ensureLoaded() {
    final existing = _instance;
    if (existing != null) return existing;
    for (final name in [libraryName, coreLibraryName]) {
      final path = findLibrary(name);
      if (path == null) continue;
      final native = _open(path);
      if (native != null) {
        _instance = native;
        return native;
      }
    }
    return null;
  }

  static CencNative? _open(String path) {
    try {
      final library = DynamicLibrary.open(path);
      return CencNative._(
        library
            .lookupFunction<_CreateNative, _CreateDart>('fp_cenc_index_create'),
        library.lookupFunction<_SpanNative, _SpanDart>('fp_cenc_index_span'),
        library.lookupFunction<_DecryptNative, _DecryptDart>('fp_cenc_decrypt'),
        library.lookupFunction<_IndexInt64Native, _IndexInt64Dart>(
          'fp_cenc_index_size',
        ),
        library.lookupFunction<_IndexInt64Native, _IndexInt64Dart>(
          'fp_cenc_index_moov_end',
        ),
        library.lookupFunction<_FreeNative, _FreeDart>('fp_cenc_index_free'),
        library
            .lookupFunction<_ErrorNative, _ErrorNative>('fp_cenc_last_error'),
      );
    } on Object {
      // The file exists but is not a decryptor (or lacks the ABI): try the
      // next candidate instead of failing the whole load.
      return null;
    }
  }

  static String? findLibrary([String name = libraryName]) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final current = Directory.current.path;
    // Sources install verified modules under decryptors/<id>/<version>/.
    // Prefer the newest downloaded copy over the bundled fallback, so a
    // cloud update takes effect without replacing the app package.
    try {
      final root = Directory(joinPath(exeDir, 'decryptors'));
      if (root.existsSync()) {
        final rootPath = root.path;
        final installed = <File>[];
        for (final entity in root.listSync(recursive: true)) {
          if (entity is File &&
              entity.uri.pathSegments.last == name &&
              entity.parent.path != rootPath) {
            installed.add(entity);
          }
        }
        if (installed.isNotEmpty) {
          installed.sort((a, b) {
            return b.statSync().modified.compareTo(a.statSync().modified);
          });
          return installed.first.path;
        }
      }
    } on Object {
      // Fall through to the bundled copy.
    }
    for (final candidate in [
      joinPath(joinPath(exeDir, 'decryptors'), name),
      joinPath(exeDir, name),
      joinPath(current, name),
      joinPath(
        joinPath(joinPath(joinPath(current, 'native'), 'cenc'), 'build'),
        name,
      ),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Builds an index from a window of the file that contains moov. [base] is
  /// the absolute offset of the window start.
  CencIndex? createIndex(Uint8List data,
      {required int base, required int fileSize}) {
    if (data.isEmpty) return null;
    final pointer = malloc.allocate<Uint8>(data.length);
    try {
      pointer.asTypedList(data.length).setAll(0, data);
      final handle = _create(pointer, data.length, base, fileSize);
      if (handle == nullptr) return null;
      return CencIndex._(this, handle, _size(handle), _moovEnd(handle));
    } finally {
      malloc.free(pointer);
    }
  }

  String lastError() => _error().toDartString();
}

Uint8List keyFromHex(String hex) {
  final clean = hex.trim();
  if (clean.length < 32) return Uint8List(0);
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
