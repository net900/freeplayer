import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../gateway/source_api.dart';
import '../library/local_library.dart';
import '../local/local_thumbs.dart';
import '../settings/settings.dart';
import '../sp/models.dart';
import '../sp/quality.dart';
import '../storage/paths.dart';

/// One episode to fetch. The asset URL the gateway hands out already serves
/// decrypted bytes, so the file on disk is a plain playable MP4.
class DownloadTask {
  const DownloadTask({
    required this.itemId,
    required this.episodeId,
    required this.seriesKey,
    required this.title,
    required this.episodeLabel,
    required this.quality,
    this.cover = '',
    this.episodeIndex = 0,
  });

  final String itemId;
  final String episodeId;
  final String seriesKey;
  final String title;
  final String episodeLabel;
  final String quality;
  final String cover;
  final int episodeIndex;

  String get assetId => '$seriesKey|$episodeId';
}

/// Queued/active downloads with progress, persisted as [DownloadRecord].
///
/// Source URLs come from `/play`; each task keeps the api it was queued with
/// so switching sources cannot mix them up.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.library,
    required AppSettings Function() settings,
  }) : _settings = settings;

  final LocalLibrary library;
  final AppSettings Function() _settings;

  final Map<String, DownloadRecord> _records = {};
  final Map<String, double?> _progress = {};
  final Map<String, SourceApi> _apis = {};
  final List<DownloadTask> _queue = [];
  final List<String> _active = [];
  final Set<String> _cancelled = {};
  bool _loaded = false;
  bool _pumping = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      for (final record in await library.downloads()) {
        // A record that was mid-flight when the app closed has no worker
        // behind it any more; surface it as failed instead of a fake bar.
        if (record.state == 'downloading' || record.state == 'queued') {
          // Keep the finished segments: a paused download can continue.
          final stale = record.copyWith(
            state: record.segmentsDone > 0 ? 'paused' : 'error',
          );
          _records[record.assetId] = stale;
          unawaited(library.addDownload(stale));
          continue;
        }
        _records[record.assetId] = record;
      }
    } on Object {
      // A broken store simply starts empty.
    }
    notifyListeners();
  }

  List<DownloadRecord> get records {
    final list = _records.values.toList(growable: false);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  DownloadRecord? recordFor(String seriesKey, String episodeId) {
    if (episodeId.isEmpty) return null;
    return _records['$seriesKey|$episodeId'];
  }

  /// A finished record whose file is still on disk: playback should take the
  /// local path instead of the network.
  String? localPathFor(String seriesKey, String episodeId) {
    final record = recordFor(seriesKey, episodeId);
    if (record == null || record.state != 'done' || record.path.isEmpty) {
      return null;
    }
    return File(record.path).existsSync() ? record.path : null;
  }

  bool isDownloading(String assetId) =>
      _active.contains(assetId) || _queue.any((task) => task.assetId == assetId);

  double? progressOf(String assetId) {
    final live = _progress[assetId];
    if (live != null) return live;
    final record = _records[assetId];
    if (record == null || record.segmentsTotal <= 0) return null;
    return (record.segmentsDone / record.segmentsTotal).clamp(0.0, 1.0);
  }

  /// Queues a failed or paused record again. HLS downloads continue from the
  /// segments already written; other states restart.
  void retry(SourceApi api, DownloadRecord record) {
    final parts = record.seriesKey.split(':');
    final itemId = parts.length > 1 ? parts.sublist(1).join(':') : '';
    if (itemId.isEmpty || record.episodeId.isEmpty) return;
    final task = DownloadTask(
      itemId: itemId,
      episodeId: record.episodeId,
      seriesKey: record.seriesKey,
      title: record.title,
      episodeLabel: record.episodeLabel,
      quality: record.quality,
      cover: record.cover,
      episodeIndex: record.episodeIndex,
    );
    _apis[task.assetId] = api;
    _cancelled.remove(task.assetId);
    final next = record.copyWith(state: 'queued');
    _records[task.assetId] = next;
    unawaited(library.addDownload(next));
    if (!_queue.any((queued) => queued.assetId == task.assetId) &&
        !_active.contains(task.assetId)) {
      _queue.add(task);
      unawaited(_pump());
    }
    notifyListeners();
  }

  void enqueueAll(SourceApi api, Iterable<DownloadTask> tasks) {
    for (final task in tasks) {
      _apis[task.assetId] = api;
      final existing = _records[task.assetId];
      if (existing != null &&
          existing.state == 'done' &&
          existing.path.isNotEmpty &&
          File(existing.path).existsSync()) {
        continue;
      }
      _cancelled.remove(task.assetId);
      final record = DownloadRecord(
        assetId: task.assetId,
        seriesKey: task.seriesKey,
        title: task.title,
        state: 'queued',
        createdAt: DateTime.now().toIso8601String(),
        episodeId: task.episodeId,
        episodeLabel: task.episodeLabel,
        quality: task.quality,
        cover: task.cover,
        episodeIndex: task.episodeIndex,
      );
      _records[task.assetId] = record;
      unawaited(library.addDownload(record));
      if (!_queue.any((queued) => queued.assetId == task.assetId)) {
        _queue.add(task);
      }
    }
    notifyListeners();
    unawaited(_pump());
  }

  void cancel(String assetId) {
    _cancelled.add(assetId);
    _queue.removeWhere((task) => task.assetId == assetId);
    _update(assetId, (record) => record.copyWithState('cancelled'));
    notifyListeners();
  }

  Future<void> remove(DownloadRecord record) async {
    cancel(record.assetId);
    if (record.path.isNotEmpty) {
      try {
        final file = File(record.path);
        if (file.existsSync()) file.deleteSync();
      } on Object {
        // A locked/missing file should not block removing the entry.
      }
    }
    _records.remove(record.assetId);
    _progress.remove(record.assetId);
    await library.removeDownload(record.assetId);
    notifyListeners();
  }

  /// Clears every record. Files are only removed when [deleteFiles] is set:
  /// the default keeps the user's videos on disk.
  Future<void> clearAll({bool deleteFiles = false}) async {
    for (final record in [..._records.values]) {
      cancel(record.assetId);
      if (deleteFiles && record.path.isNotEmpty) {
        try {
          final file = File(record.path);
          if (file.existsSync()) file.deleteSync();
        } on Object {
          // Best-effort.
        }
      }
      await library.removeDownload(record.assetId);
    }
    _records.clear();
    _progress.clear();
    _queue.clear();
    if (!deleteFiles) {
      notifyListeners();
      return;
    }
    // Remove the empty series folders the downloader created.
    try {
      final root = Directory(_settings().downloadDirectory);
      if (root.existsSync()) {
        for (final entity in root.listSync()) {
          if (entity is Directory && entity.listSync().isEmpty) {
            entity.deleteSync();
          }
        }
      }
    } on Object {
      // The user may have pointed at a folder we cannot inspect.
    }
    notifyListeners();
  }

  /// Total size of finished downloads, for the settings row.
  int get totalBytes => _records.values
      .where((record) => record.state == 'done')
      .fold(0, (sum, record) => sum + record.bytes);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    final limit = _settings().maxConcurrentDownloads.clamp(1, 5);
    while (_queue.isNotEmpty) {
      while (_active.length >= limit) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final task = _queue.removeAt(0);
      _active.add(task.assetId);
      unawaited(_run(task).whenComplete(() {
        _active.remove(task.assetId);
        notifyListeners();
      }));
    }
    _pumping = false;
  }

  Future<void> _run(DownloadTask task) async {
    final api = _apis[task.assetId];
    if (api == null) return;
    final settings = _settings();
    try {
      final quotaBytes = settings.offlineQuotaGB * 1024 * 1024 * 1024;
      final usedBytes = _records.values
          .where((record) => record.state == 'done')
          .fold<int>(0, (sum, record) => sum + record.bytes);
      if (quotaBytes > 0 && usedBytes >= quotaBytes) {
        throw SpException(
          SpErrorCode.unsupported,
          '离线配额已满（${settings.offlineQuotaGB} GB），请调大配额或删除旧下载',
        );
      }
      _update(task.assetId, (record) => record.copyWithState('downloading'));
      final plan = await api.play(PlayRequest(
        itemId: task.itemId,
        episodeId: task.episodeId,
        quality: task.quality.isEmpty ? Quality.auto : task.quality,
      ));
      if (_cancelled.contains(task.assetId)) return;
      final stream = Quality.pick(plan.streams, quality: task.quality);
      final url = stream?.url ?? '';
      if (url.isEmpty) throw const SpException(SpErrorCode.unsupported, '该集没有可下载的流');
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        throw const SpException(SpErrorCode.unsupported, '下载地址不可用');
      }

      final root = Directory(settings.downloadDirectory.isEmpty
          ? defaultDownloadDirectory()
          : settings.downloadDirectory);
      // Two works can share a title. A folder already owned by another work
      // would make them overwrite each other's episodes and delete the file
      // the first record still points at.
      var folderName = _safeName(task.title);
      final folderPath = joinPath(root.path, folderName);
      final takenByOther = _records.values.any(
        (record) =>
            record.seriesKey != task.seriesKey &&
            record.path.startsWith(folderPath),
      );
      if (takenByOther && Directory(folderPath).existsSync()) {
        folderName = '$folderName (${_safeName(task.itemId)})';
      }
      final folder = Directory(joinPath(root.path, folderName));
      folder.createSync(recursive: true);
      final baseName =
          _safeName(task.episodeLabel.isEmpty ? task.episodeId : task.episodeLabel);

      // HLS playlists are fetched segment by segment, then remuxed to MP4
      // with the ffmpeg shipped beside the app; anything else is streamed
      // straight to disk.
      final hls = uri.path.toLowerCase().endsWith('.m3u8');
      var target = File(joinPath(folder.path, '$baseName.mp4'));

      int written;
      if (hls) {
        final tsPart = File(joinPath(folder.path, '$baseName.ts.part'));
        final record = _records[task.assetId];
        var start = record?.segmentsDone ?? 0;
        final total = record?.segmentsTotal ?? 0;
        if (start > 0 && (!tsPart.existsSync() || tsPart.lengthSync() == 0)) {
          start = 0;
        }
        if (start > 0) {
          // Trim anything written after the last persisted checkpoint, so
          // resuming cannot duplicate a segment.
          final checkpoint = record?.bytes ?? 0;
          final actual = tsPart.lengthSync();
          if (checkpoint <= 0) {
            start = 0;
          } else if (actual > checkpoint) {
            final raf = tsPart.openSync(mode: FileMode.append);
            raf.truncateSync(checkpoint);
            raf.closeSync();
          } else if (actual < checkpoint) {
            start = 0;
          }
        }
        final playlist = await _fetchText(uri);
        written = await _downloadHls(
          uri,
          playlist,
          tsPart,
          task.assetId,
          start,
          total,
        );
        if (written < 0) {
          _cleanup(tsPart, target);
          return;
        }
        final remuxed = await _remuxToMp4(tsPart, target);
        if (remuxed) {
          try {
            tsPart.deleteSync();
          } on Object {
            // The MP4 is complete; a leftover temp file is harmless.
          }
          written = target.lengthSync();
        } else {
          // No ffmpeg (or it failed): keep the raw transport stream.
          target = File(joinPath(folder.path, '$baseName.ts'));
          if (target.existsSync()) target.deleteSync();
          tsPart.renameSync(target.path);
          written = target.lengthSync();
        }
      } else {
        final part = File('${target.path}.part');
        written = await _saveDirect(uri, part, task.assetId);
        if (written < 0) {
          _cleanup(part, target);
          return;
        }
        if (target.existsSync()) target.deleteSync();
        part.renameSync(target.path);
        written = target.lengthSync();
      }
      // The user may have cancelled while the remux was running; a finished
      // MP4 must not flip a cancelled task back to done.
      if (_cancelled.contains(task.assetId)) {
        _cleanup(target, target);
        return;
      }
      _progress[task.assetId] = 1;
      final record = _records[task.assetId]?.copyWith(
        state: 'done',
        path: target.path,
        bytes: written,
        segmentsDone: 0,
        segmentsTotal: 0,
      );
      if (record != null) {
        _records[task.assetId] = record;
        await library.addDownload(record);
      }
    } on Object catch (error) {
      if (_cancelled.contains(task.assetId)) return;
      _update(
        task.assetId,
        (record) => record.copyWith(state: 'error', path: ''),
      );
      debugPrint('download failed ${task.title}: $error');
    } finally {
      notifyListeners();
    }
  }


  Future<String> _readBody(HttpClientResponse response) async {
    final builder = await response.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        builder.add(chunk);
        return builder;
      },
    );
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<String> _fetchText(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.headers
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.connectionHeader, 'close');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw SpException(
          SpErrorCode.upstreamFailed,
          '下载失败：源返回了 ${response.statusCode}',
        );
      }
      return await _readBody(response).timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }

  /// Streams a direct media URL to disk. Returns bytes written, or -1 if
  /// cancelled.
  Future<int> _saveDirect(Uri uri, File part, String assetId) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.headers
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.connectionHeader, 'close');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw SpException(
          SpErrorCode.upstreamFailed,
          '下载失败：源返回了 ${response.statusCode}',
        );
      }
      final total = response.contentLength;
      final sink = part.openWrite();
      var written = 0;
      var lastNotify = 0;
      await for (final chunk in response) {
        if (_cancelled.contains(assetId)) {
          await sink.close();
          return -1;
        }
        sink.add(chunk);
        written += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotify > 300) {
          lastNotify = now;
          _progress[assetId] = total > 0 ? written / total : null;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      return written;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads an HLS playlist (highest variant) segment by segment.
  /// Returns bytes written, or -1 if cancelled.
  Future<int> _downloadHls(
    Uri playlistUri,
    String playlist,
    File part,
    String assetId,
    int startIndex,
    int totalHint,
  ) async {
    var text = playlist;
    var base = playlistUri;
    final variant = _highestVariant(text, base);
    if (variant != null) {
      base = variant;
      text = await _fetchText(variant);
    }
    if (RegExp(r'#EXT-X-KEY:METHOD=(?!NONE)').hasMatch(text)) {
      throw const SpException(
        SpErrorCode.unsupported,
        '暂不支持加密的 HLS 下载',
      );
    }
    final segments = <Uri>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      segments.add(base.resolve(line));
    }
    debugPrint('dl: segments=${segments.length}');
    if (segments.isEmpty) {
      throw const SpException(SpErrorCode.unsupported, '播放列表没有分片');
    }

    // A different segment count means the playlist changed; start over.
    var start = startIndex;
    if (totalHint > 0 && totalHint != segments.length) start = 0;
    if (start >= segments.length) start = 0;
    if (start > 0 && part.existsSync()) {
      final expected = _records[assetId]?.segmentsDone ?? 0;
      if (expected != start) start = 0;
    }
    if (start == 0 && part.existsSync()) part.deleteSync();

    final total = segments.length;
    final sink = part.openWrite(
      mode: start > 0 ? FileMode.append : FileMode.write,
    );
    var written = start > 0 && part.existsSync() ? part.lengthSync() : 0;
    var lastNotify = 0;

    // Segments are independent, so fetch them on six connections in order-
    // preserving parallel workers; a single sequential connection was the
    // reason a 300-segment episode took minutes.
    final pending = <int, List<int>>{};
    var nextToFetch = start;
    var nextToWrite = start;
    Object? fatal;
    const windowSize = 24;
    final workerCount = _settings().downloadSegments.clamp(1, 12);

    Future<List<int>> fetch(HttpClient client, int index) async {
      try {
        return await _fetchVia(client, segments[index]);
      } on Object {
        final fresh = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        try {
          return await _fetchVia(fresh, segments[index]);
        } finally {
          fresh.close(force: true);
        }
      }
    }

    Future<void> worker() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        while (true) {
          if (fatal != null || _cancelled.contains(assetId)) return;
          if (nextToFetch >= total) return;
          if (nextToFetch >= nextToWrite + windowSize) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final index = nextToFetch++;
          try {
            pending[index] = await fetch(client, index);
          } on Object catch (error) {
            fatal = error;
            return;
          }
        }
      } finally {
        client.close(force: true);
      }
    }

    final workers = <Future<void>>[
      for (var w = 0; w < workerCount && w < total - start; w++) worker(),
    ];

    try {
      while (nextToWrite < total) {
        if (fatal != null) break;
        if (_cancelled.contains(assetId)) {
          await sink.flush();
          await sink.close();
          await Future.wait(workers);
          return -1;
        }
        final bytes = pending.remove(nextToWrite);
        if (bytes == null) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        sink.add(bytes);
        written += bytes.length;
        nextToWrite++;
        if (nextToWrite % 5 == 0) await sink.flush();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotify > 300 || nextToWrite == total) {
          lastNotify = now;
          _progress[assetId] = nextToWrite / total;
          notifyListeners();
        }
        final record = _records[assetId];
        if (record != null && (nextToWrite % 5 == 0 || nextToWrite == total)) {
          final next = record.copyWith(
            state: 'downloading',
            bytes: written,
            segmentsDone: nextToWrite,
            segmentsTotal: total,
          );
          _records[assetId] = next;
          unawaited(library.addDownload(next));
        }
      }
      await Future.wait(workers);
      if (fatal != null) throw fatal!;
      await sink.flush();
      await sink.close();
    } on Object {
      try {
        await sink.close();
      } on Object {
        // Already closed.
      }
      rethrow;
    }
    return written;
  }

  /// Fetches one segment over an existing keep-alive connection.
  Future<List<int>> _fetchVia(HttpClient client, Uri uri) async {
    final request =
        await client.getUrl(uri).timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response =
        await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      throw SpException(
        SpErrorCode.upstreamFailed,
        '下载失败：分片返回了 ${response.statusCode}',
      );
    }
    final builder = await response.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        builder.add(chunk);
        return builder;
      },
    ).timeout(const Duration(seconds: 45));
    return builder.takeBytes();
  }

  Uri? _highestVariant(String text, Uri base) {
    final lines = text.split('\n');
    var bestBandwidth = -1;
    Uri? best;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final match = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
      final bandwidth = match == null ? 0 : int.parse(match.group(1)!);
      String? target;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        target = candidate;
        break;
      }
      if (target == null) continue;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        best = base.resolve(target);
      }
    }
    return best;
  }

  /// Remuxes a downloaded transport stream into MP4 without re-encoding.
  /// Returns false when ffmpeg is unavailable or refused the input, so the
  /// caller can fall back to the .ts file.
  Future<bool> _remuxToMp4(File source, File target) async {
    if (!source.existsSync() || source.lengthSync() == 0) return false;
    final ffmpeg = LocalThumbs.tool('ffmpeg');
    if (ffmpeg == null) {
      debugPrint('dl: ffmpeg not found, keeping .ts');
      return false;
    }
    try {
      if (target.existsSync()) target.deleteSync();
      final result = await Process.run(ffmpeg, [
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        source.path,
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        target.path,
      ]).timeout(const Duration(minutes: 10));
      if (result.exitCode != 0) {
        debugPrint('dl: remux failed ${result.exitCode} ${result.stderr}');
        return false;
      }
      return target.existsSync() && target.lengthSync() > 0;
    } on Object catch (error) {
      debugPrint('dl: remux error $error');
      return false;
    }
  }

  void _cleanup(File part, File target) {
    try {
      if (part.existsSync()) part.deleteSync();
      if (target.existsSync()) target.deleteSync();
    } on Object {
      // Best-effort.
    }
  }

  void _update(String assetId, DownloadRecord Function(DownloadRecord) edit) {
    final record = _records[assetId];
    if (record == null) return;
    final next = edit(record);
    _records[assetId] = next;
    unawaited(library.addDownload(next));
    notifyListeners();
  }

  static final RegExp _reservedNames = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
    caseSensitive: false,
  );

  /// One path segment that Windows accepts. `.`/`..` would escape the
  /// download directory, and trailing dots/spaces silently break paths.
  String _safeName(String raw) {
    var cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    while (cleaned.endsWith('.') || cleaned.endsWith(' ')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trimRight();
    }
    if (cleaned.length > 60) cleaned = cleaned.substring(0, 60).trimRight();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'untitled';
    if (_reservedNames.hasMatch(cleaned)) return '_$cleaned';
    return cleaned;
  }
}
