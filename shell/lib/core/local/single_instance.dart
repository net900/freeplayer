import 'dart:convert';
import 'dart:io';

/// Keeps exactly one shell process: a second launch forwards its file path to
/// the running instance and exits (PRD §5.6).
class SingleInstance {
  SingleInstance._();

  static const int _port = 45987;
  static ServerSocket? _server;
  static RandomAccessFile? _lock;

  static bool get isPrimary => _server != null;

  /// Windows lets two processes bind the same loopback port with SO_REUSEADDR,
  /// so the port alone is not an ownership test. An exclusive file lock is.
  static Future<bool> _acquireLock() async {
    final exe = File(Platform.resolvedExecutable);
    final lockFile = File(
      '${exe.parent.path}${Platform.pathSeparator}free_player.lock',
    );
    try {
      final raf = await lockFile.open(mode: FileMode.append);
      try {
        await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 2));
      } on Object {
        await raf.close();
        return false;
      }
      _lock = raf;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Returns true when this process owns the instance. Otherwise the optional
  /// [path] has been forwarded to the running process.
  static Future<bool> claim(
    Future<void> Function(String path) onOpen, {
    Future<void> Function()? onActivate,
  }) async {
    // Protocol launches (freeplayer:// links) arrive while the app is already
    // running. Ask the live instance first: taking the file lock below blocks
    // until the other process lets go, which left those launches hanging as
    // invisible processes that never forwarded their link.
    if (await isPrimaryAlive()) return false;
    if (!await _acquireLock()) return false;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _port,
        shared: false,
      );
      _server = server;
      server.listen((socket) {
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
          (line) async {
            final message = line.trim();
            if (message == 'activate') {
              await onActivate?.call();
              return;
            }
            if (message == 'ping') {
              // Answer without waiting for EOF: the liveness probe keeps its
              // write side open while waiting for this reply.
              socket.write('pong\n');
              await socket.flush();
              return;
            }
            if (message.startsWith('open:')) {
              final path = message.substring(5).trim();
              if (path.isNotEmpty) await onOpen(path);
            } else if (message.isNotEmpty) {
              await onOpen(message);
            }
          },
          onError: (_) {},
          onDone: socket.destroy,
          cancelOnError: true,
        );
      });
      return true;
    } on SocketException {
      // The lock still proves ownership; only handoff is unavailable.
      return true;
    }
  }

  static Future<void> forward(String path) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 800),
      );
      socket.write('activate\n');
      final value = path.trim();
      if (value.isNotEmpty) socket.write('open:$path\n');
      await socket.flush();
      // close() waits for the peer to close too; the primary keeps the socket
      // open after handing off, so destroy it here.
      socket.destroy();
    } on SocketException {
      // The other instance disappeared between claim and forward.
    }
  }

  /// Distinguishes "another Free Player owns the port" from "the port is taken
  /// by an unrelated process", so a conflict never produces a silent no-window
  /// exit.
  static Future<bool> isPrimaryAlive() async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 600),
      );
      socket.write('ping\n');
      await socket.flush();
      final reply = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(milliseconds: 800));
      socket.destroy();
      return reply.trim() == 'pong';
    } on Object {
      return false;
    }
  }

  static Future<void> release() async {
    await _server?.close();
    _server = null;
    try {
      await _lock?.unlock();
      await _lock?.close();
    } on Object {
      // The OS releases it on exit anyway.
    }
    _lock = null;
  }
}
