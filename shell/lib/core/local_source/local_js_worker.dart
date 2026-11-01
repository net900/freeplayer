import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';

import '../sp/models.dart';

/// One evaluation's outcome: the value QuickJS returned, or its error text.
class LocalJsEvaluation {
  const LocalJsEvaluation(this.value, this.error);

  final String value;
  final String error;

  bool get failed => error.isNotEmpty;
}

/// Owns one local source's QuickJS runtime on a dedicated isolate.
///
/// QuickJS evaluates synchronously. A local source answers every `/play` by
/// running its own script, and a page opens with a burst of play requests, so
/// evaluating on the UI isolate dropped frames for as long as the burst ran.
/// The isolate keeps the package's state (counters, caches) in one place and
/// serialises calls, so the UI never waits on JavaScript.
///
/// [QuickJsRuntime2] is plain FFI over the bundled QuickJS library, which is
/// what makes this possible; the channel-backed runtime cannot be created
/// outside the root isolate.
class LocalJsWorker {
  LocalJsWorker._(
    this._isolate,
    this._calls,
    this._replies,
    this.meta,
    this.hasHero,
    this.hasSuggest,
    this.dynamicHeaders,
  );

  final Isolate _isolate;
  final SendPort _calls;
  final ReceivePort _replies;

  /// `JSON.stringify(__FP_SOURCE)` for the loaded package.
  final String meta;
  final bool hasHero;
  final bool hasSuggest;
  final bool dynamicHeaders;

  final Map<int, Completer<LocalJsEvaluation>> _pending = {};
  int _nextId = 0;
  bool _closed = false;

  /// Loads [source] in a new isolate and waits until the package answers.
  static Future<LocalJsWorker> start(String source) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      [replies.sendPort, source],
      debugName: 'fp-local-js',
    );
    isolate.addOnExitListener(replies.sendPort, response: const ['exit']);

    final ready = Completer<LocalJsWorker>();
    LocalJsWorker? worker;
    replies.listen((message) {
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'ready':
          final created = LocalJsWorker._(
            isolate,
            message[1] as SendPort,
            replies,
            message[2] as String,
            message[3] == true,
            message[4] == true,
            message[5] == true,
          );
          worker = created;
          if (!ready.isCompleted) ready.complete(created);
        case 'error':
          final text = '${message[1]}';
          if (ready.isCompleted) {
            worker?._failAll(text);
          } else {
            ready.completeError(
              SpException(SpErrorCode.upstreamFailed, text),
            );
          }
        case 'exit':
          worker?._failAll('本地源已停止');
          if (!ready.isCompleted) {
            ready.completeError(
              const SpException(SpErrorCode.upstreamFailed, '本地源启动失败'),
            );
          }
        default:
          worker?._resolve(message);
      }
    });
    return ready.future;
  }

  Future<LocalJsEvaluation> evaluate(String expression) {
    if (_closed) {
      return Future.value(const LocalJsEvaluation('', '本地源已关闭'));
    }
    final id = ++_nextId;
    final completer = Completer<LocalJsEvaluation>();
    _pending[id] = completer;
    _calls.send([id, expression]);
    return completer.future;
  }

  void _resolve(List message) {
    final id = message[0];
    if (id is! int) return;
    _pending.remove(id)?.complete(
          LocalJsEvaluation('${message[1]}', '${message[2]}'),
        );
  }

  void _failAll(String message) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(LocalJsEvaluation('', message));
      }
    }
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _failAll('本地源已关闭');
    _replies.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _workerMain(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final source = args[1] as String;
  JavascriptRuntime? runtime;
  try {
    runtime = QuickJsRuntime2(timeout: 5000);
    final evaluated = runtime.evaluate(source);
    if (evaluated.isError) {
      reply.send(['error', '本地源脚本执行失败：${evaluated.stringResult}']);
      return;
    }
    final raw = runtime.evaluate('JSON.stringify(__FP_SOURCE)');
    if (raw.isError) {
      reply.send(['error', raw.stringResult]);
      return;
    }
    final hero = runtime.evaluate('JSON.stringify(typeof __FP_SOURCE.urls.hero)');
    final suggest =
        runtime.evaluate('JSON.stringify(typeof __FP_SOURCE.urls.suggest)');
    final headers =
        runtime.evaluate('JSON.stringify(typeof __FP_SOURCE.headers)');
    final calls = ReceivePort();
    reply.send([
      'ready',
      calls.sendPort,
      raw.stringResult,
      !hero.isError && hero.stringResult.contains('function'),
      !suggest.isError && suggest.stringResult.contains('function'),
      !headers.isError && _typeName(headers.stringResult) == 'function',
    ]);
    await for (final message in calls) {
      if (message is! List || message.length != 2) continue;
      final id = message[0] as int;
      try {
        final result = runtime.evaluate(message[1] as String);
        reply.send(result.isError
            ? [id, '', result.stringResult]
            : [id, result.stringResult, '']);
      } on Object catch (error) {
        reply.send([id, '', '$error']);
      }
    }
  } on Object catch (error) {
    reply.send(['error', '$error']);
  } finally {
    runtime?.dispose();
  }
}

/// The `typeof` result arrives JSON-encoded; older runtimes return it raw.
String _typeName(String raw) {
  final text = raw.trim();
  try {
    final value = jsonDecode(text);
    return value is String ? value : text;
  } on Object {
    return text.replaceAll('"', '');
  }
}
