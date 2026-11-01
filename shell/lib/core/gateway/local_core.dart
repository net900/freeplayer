import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../storage/paths.dart';
import 'gateway_errors.dart';

typedef _StartNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PortNative = Int32 Function();
typedef _PortDart = int Function();
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();
typedef _StopNative = Void Function();
typedef _StopDart = void Function();

/// The decryption gateway compiled as a DLL and loaded in-process.
/// The app talks to it over loopback exactly like a remote gateway; nothing
/// is installed separately and it dies with the app.
class LocalCore {
  DynamicLibrary? _library;
  int _port = 0;
  String _error = '';

  bool get running => _port > 0;
  String get lastError => _error;

  /// Starts the core if the DLL ships next to the app. Returns the base URL
  /// once the HTTP API is accepting requests, or null when there is no core
  /// or it failed (the app then falls back to a configured gateway).
  Future<String?> start() async {
    if (!Platform.isWindows) return null;
    if (_port > 0) return 'http://127.0.0.1:$_port';
    final path = findLibrary();
    if (path == null) return null;
    try {
      final library = DynamicLibrary.open(path);
      final start =
          library.lookupFunction<_StartNative, _StartDart>('FPCoreStart');
      final portOf =
          library.lookupFunction<_PortNative, _PortDart>('FPCorePort');
      final errorOf =
          library.lookupFunction<_ErrorNative, _ErrorDart>('FPCoreError');
      final dataDir = joinPath(appDataDirectory().path, 'core');
      // ffmpeg lives in tools beside the executable, not beside the DLL: the
      // DLL itself sits in decryptors\.
      final toolsDir = joinPath(
        File(Platform.resolvedExecutable).parent.path,
        'tools',
      );
      final dataPointer = dataDir.toNativeUtf8();
      final toolsPointer = toolsDir.toNativeUtf8();
      try {
        start(dataPointer, toolsPointer);
      } finally {
        malloc.free(dataPointer);
        malloc.free(toolsPointer);
      }
      _library = library;

      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        final port = portOf();
        if (port > 0) {
          _port = port;
          return 'http://127.0.0.1:$port';
        }
        if (port < 0) {
          _error = errorOf().toDartString();
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      _error = '本地核心启动超时';
      return null;
    } on Object catch (error) {
      _error = describeGatewayError(error);
      return null;
    }
  }

  void stop() {
    final library = _library;
    if (library == null) return;
    try {
      library.lookupFunction<_StopNative, _StopDart>('FPCoreStop')();
    } on Object {
      // The process is exiting anyway.
    }
    _library = null;
    _port = 0;
  }

  /// The decryption DLL ships in the app's decryptor folder, with the
  /// executable itself and a `core` folder accepted as fallbacks. The name
  /// is generic and can be overridden at build time.
  static const String libraryName = String.fromEnvironment(
    'FREEPLAYER_CORE_DLL',
    defaultValue: 'freeplayer_core.dll',
  );

  static String? findLibrary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final dir in [
      joinPath(exeDir, 'decryptors'),
      exeDir,
      joinPath(exeDir, 'core'),
      Directory.current.path,
    ]) {
      final candidate = joinPath(dir, libraryName);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}
