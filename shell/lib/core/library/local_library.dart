import '../sp/models.dart';
import '../storage/local_store.dart';

/// Local playback state. Progress/history/favorites never leave the device
/// (PRD §18.1 #8). `series_key` is `{source_id}:{item_id}`.
class LibraryRecord {
  const LibraryRecord({
    required this.seriesKey,
    required this.title,
    this.cover = '',
    this.sourceId = '',
    this.itemId = '',
    this.episodeId = '',
    this.episodeIndex = 0,
    this.positionSec = 0,
    this.durationSec = 0,
    this.updatedAt = '',
    this.episodeCount = 0,
    this.finished = false,
    this.category = '',
  });

  final String seriesKey;
  final String title;
  final String cover;
  final String sourceId;
  final String itemId;
  final String episodeId;
  final int episodeIndex;
  final int positionSec;
  final int durationSec;
  final String updatedAt;
  final int episodeCount;
  final bool finished;
  final String category;

  double get progress =>
      durationSec <= 0 ? 0 : (positionSec / durationSec).clamp(0.0, 1.0);

  LibraryRecord copyWith({
    String? title,
    String? cover,
    String? episodeId,
    int? episodeIndex,
    int? positionSec,
    int? durationSec,
    String? updatedAt,
    int? episodeCount,
    bool? finished,
    String? category,
  }) {
    return LibraryRecord(
      seriesKey: seriesKey,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      sourceId: sourceId,
      itemId: itemId,
      episodeId: episodeId ?? this.episodeId,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      positionSec: positionSec ?? this.positionSec,
      durationSec: durationSec ?? this.durationSec,
      updatedAt: updatedAt ?? this.updatedAt,
      episodeCount: episodeCount ?? this.episodeCount,
      finished: finished ?? this.finished,
      category: category ?? this.category,
    );
  }

  Map<String, dynamic> toJson() => {
        'series_key': seriesKey,
        'title': title,
        'cover': cover,
        'source_id': sourceId,
        'item_id': itemId,
        'episode_id': episodeId,
        'episode_index': episodeIndex,
        'position_sec': positionSec,
        'duration_sec': durationSec,
        'updated_at': updatedAt,
        'episode_count': episodeCount,
        'finished': finished,
        'category': category,
      };

  factory LibraryRecord.fromJson(Map<String, dynamic> json) {
    return LibraryRecord(
      seriesKey: str(json['series_key']),
      title: str(json['title']),
      cover: str(json['cover']),
      sourceId: str(json['source_id']),
      itemId: str(json['item_id']),
      episodeId: str(json['episode_id']),
      episodeIndex: intOr(json['episode_index']),
      positionSec: intOr(json['position_sec']),
      durationSec: intOr(json['duration_sec']),
      updatedAt: str(json['updated_at']),
      episodeCount: intOr(json['episode_count']),
      finished: boolOr(json['finished']),
      category: str(json['category']),
    );
  }
}

class DownloadRecord {
  const DownloadRecord({
    required this.assetId,
    required this.seriesKey,
    this.title = '',
    this.path = '',
    this.bytes = 0,
    this.state = 'queued',
    this.createdAt = '',
    this.episodeId = '',
    this.episodeLabel = '',
    this.quality = '',
    this.cover = '',
    this.episodeIndex = 0,
    this.segmentsDone = 0,
    this.segmentsTotal = 0,
  });

  final String assetId;
  final String seriesKey;
  final String title;
  final String path;
  final int bytes;
  final String state;
  final String createdAt;
  final String episodeId;
  final String episodeLabel;
  final String quality;
  final String cover;
  final int episodeIndex;

  /// HLS segment progress, so an interrupted download can continue.
  final int segmentsDone;
  final int segmentsTotal;

  DownloadRecord copyWith({
    String? state,
    String? path,
    int? bytes,
    int? segmentsDone,
    int? segmentsTotal,
  }) {
    return DownloadRecord(
      assetId: assetId,
      seriesKey: seriesKey,
      title: title,
      path: path ?? this.path,
      bytes: bytes ?? this.bytes,
      state: state ?? this.state,
      createdAt: createdAt,
      episodeId: episodeId,
      episodeLabel: episodeLabel,
      quality: quality,
      cover: cover,
      episodeIndex: episodeIndex,
      segmentsDone: segmentsDone ?? this.segmentsDone,
      segmentsTotal: segmentsTotal ?? this.segmentsTotal,
    );
  }

  DownloadRecord copyWithState(String next) => copyWith(state: next);

  Map<String, dynamic> toJson() => {
        'asset_id': assetId,
        'series_key': seriesKey,
        'title': title,
        'path': path,
        'bytes': bytes,
        'state': state,
        'created_at': createdAt,
        'episode_id': episodeId,
        'episode_label': episodeLabel,
        'quality': quality,
        'cover': cover,
        'episode_index': episodeIndex,
        'segments_done': segmentsDone,
        'segments_total': segmentsTotal,
      };

  factory DownloadRecord.fromJson(Map<String, dynamic> json) {
    return DownloadRecord(
      assetId: str(json['asset_id']),
      seriesKey: str(json['series_key']),
      title: str(json['title']),
      path: str(json['path']),
      bytes: intOr(json['bytes']),
      state: str(json['state']),
      createdAt: str(json['created_at']),
      episodeId: str(json['episode_id']),
      episodeLabel: str(json['episode_label']),
      quality: str(json['quality']),
      cover: str(json['cover']),
      episodeIndex: intOr(json['episode_index']),
      segmentsDone: intOr(json['segments_done']),
      segmentsTotal: intOr(json['segments_total']),
    );
  }
}

class LocalLibrary {
  LocalLibrary(this._store);

  final LocalStore _store;

  /// History, favourites, positions and downloads all live in one JSON file
  /// and every mutation is read-modify-write. Two of them running at once
  /// (three downloads finishing while the player saves progress) used to drop
  /// each other's change, so all writes go through one queue.
  Future<void> _writeQueue = Future<void>.value();

  Future<void> _mutate(Future<void> Function() body) {
    final next = _writeQueue.then((_) => body());
    _writeQueue = next.catchError((Object _) {});
    return next;
  }

  Future<List<LibraryRecord>> history() async {
    final data = await _store.read();
    return _records(data['history']);
  }

  Future<List<LibraryRecord>> favorites() async {
    final data = await _store.read();
    return _records(data['favorites']);
  }

  Future<List<DownloadRecord>> downloads() async {
    final data = await _store.read();
    return listOr(data['downloads'])
        .map((e) => DownloadRecord.fromJson(mapOr(e)))
        .toList(growable: false);
  }

  static const _positionsKey = 'episode_positions';

  /// Per-episode position, so jumping to another episode and back continues
  /// where that episode stopped. Keyed by `series_key|episode_id`.
  Future<int> episodePosition(String seriesKey, String episodeId) async {
    if (episodeId.isEmpty) return 0;
    final data = await _store.read();
    final all = mapOr(data[_positionsKey]);
    final row = mapOr(all['$seriesKey|$episodeId']);
    final pos = intOr(row['position_sec']);
    return pos > 0 ? pos : 0;
  }

  /// Every stored position for one series, keyed by episode id.
  Future<Map<String, int>> episodePositions(String seriesKey) async {
    final data = await _store.read();
    final all = mapOr(data[_positionsKey]);
    final prefix = '$seriesKey|';
    final out = <String, int>{};
    for (final entry in all.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final pos = intOr(mapOr(entry.value)['position_sec']);
      if (pos > 0) out[entry.key.substring(prefix.length)] = pos;
    }
    return out;
  }

  /// Every stored episode position with its duration, keyed
  /// `series_key|episode_id`. The account's own history reports durations in
  /// a different unit, so the local map is the only trustworthy source for
  /// the progress bar.
  Future<Map<String, ({int position, int duration})>> episodeProgress() async {
    final data = await _store.read();
    final all = mapOr(data[_positionsKey]);
    final out = <String, ({int position, int duration})>{};
    for (final entry in all.entries) {
      final row = mapOr(entry.value);
      final position = intOr(row['position_sec']);
      final duration = intOr(row['duration_sec']);
      if (position <= 0 || duration <= 0) continue;
      out[entry.key] = (position: position, duration: duration);
    }
    return out;
  }

  Future<void> recordEpisodePosition(
    String seriesKey,
    String episodeId, {
    required int positionSec,
    required int durationSec,
  }) async {
    if (episodeId.isEmpty) return;
    await _mutate(() async {
      final data = await _store.read();
      final all = Map<String, dynamic>.from(mapOr(data[_positionsKey]));
      all['$seriesKey|$episodeId'] = {
        'position_sec': positionSec,
        'duration_sec': durationSec,
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (all.length > 300) {
        final entries = all.entries.toList()
          ..sort((a, b) => str(mapOr(b.value)['updated_at'])
              .compareTo(str(mapOr(a.value)['updated_at'])));
        all
          ..clear()
          ..addEntries(entries.take(300));
      }
      await _store.write({...data, _positionsKey: all});
    });
  }

  /// Playback speed is one global preference: it survives episode changes,
  /// series changes and restarts.
  Future<double> playbackRate() async {
    final data = await _store.read();
    final raw = data['playback_rate'];
    if (raw is num && raw >= 0.25 && raw <= 4) return raw.toDouble();
    return 1.0;
  }

  Future<void> setPlaybackRate(double rate) => _mutate(() async {
        final data = await _store.read();
        await _store.write({...data, 'playback_rate': rate});
      });

  Future<bool> isFavorite(String seriesKey) async {
    final list = await favorites();
    return list.any((record) => record.seriesKey == seriesKey);
  }

  Future<void> toggleFavorite(LibraryRecord record) => _mutate(() async {
        final data = await _store.read();
        final list = _records(data['favorites']);
        final exists = list.any((item) => item.seriesKey == record.seriesKey);
        final next = exists
            ? list.where((item) => item.seriesKey != record.seriesKey).toList()
            : <LibraryRecord>[record, ...list];
        final hidden = {..._stringSet(data['hidden_favorites'])};
        // Re-adding a title that was deleted locally must make it visible again.
        if (!exists) hidden.remove(record.seriesKey);
        await _store.write({
          ...data,
          'favorites': next.map((e) => e.toJson()).toList(),
          'hidden_favorites': hidden.toList(),
        });
      });

  /// Batch delete favourites. The keys are also hidden so a remote shelf that
  /// has not processed the delete yet cannot re-add them on the next merge.
  Future<void> removeFavorites(Set<String> seriesKeys) async {
    if (seriesKeys.isEmpty) return;
    await _mutate(() async {
      final data = await _store.read();
      final list = _records(data['favorites'])
          .where((item) => !seriesKeys.contains(item.seriesKey))
          .toList();
      final hidden = {..._stringSet(data['hidden_favorites']), ...seriesKeys};
      await _store.write({
        ...data,
        'favorites': list.map((e) => e.toJson()).toList(),
        'hidden_favorites': hidden.toList(),
      });
    });
  }

  Future<Set<String>> hiddenFavorites() async {
    final data = await _store.read();
    return _stringSet(data['hidden_favorites']);
  }

  Future<void> recordProgress(LibraryRecord record) => _mutate(() async {
        final data = await _store.read();
        final list = _records(data['history']);
        final next = <LibraryRecord>[
          record,
          ...list.where((item) => item.seriesKey != record.seriesKey),
        ];
        final hidden = {..._stringSet(data['hidden_history'])}
          ..remove(record.seriesKey);
        await _store.write({
          ...data,
          'history': next.map((e) => e.toJson()).toList(),
          'hidden_history': hidden.toList(),
        });
      });

  /// Delete history locally. Remote history is filtered by these keys when the
  /// local and account lists are merged.
  Future<void> removeHistory(Set<String> seriesKeys) async {
    if (seriesKeys.isEmpty) return;
    await _mutate(() async {
      final data = await _store.read();
      final list = _records(data['history'])
          .where((item) => !seriesKeys.contains(item.seriesKey))
          .toList();
      final hidden = {..._stringSet(data['hidden_history']), ...seriesKeys};
      await _store.write({
        ...data,
        'history': list.map((e) => e.toJson()).toList(),
        'hidden_history': hidden.toList(),
      });
    });
  }

  Future<Set<String>> hiddenHistory() async {
    final data = await _store.read();
    return _stringSet(data['hidden_history']);
  }

  Set<String> _stringSet(Object? raw) {
    if (raw is! List) return <String>{};
    return raw.map((value) => value.toString()).where((v) => v.isNotEmpty).toSet();
  }

  Future<void> addDownload(DownloadRecord record) => _mutate(() async {
        final data = await _store.read();
        final list = await downloads();
        final next = <DownloadRecord>[
          record,
          ...list.where((item) => item.assetId != record.assetId),
        ];
        await _store.write({
          ...data,
          'downloads': next.map((e) => e.toJson()).toList(),
        });
      });

  Future<void> removeDownload(String assetId) => _mutate(() async {
        final data = await _store.read();
        final list = await downloads();
        final next = list.where((item) => item.assetId != assetId).toList();
        await _store.write({
          ...data,
          'downloads': next.map((e) => e.toJson()).toList(),
        });
      });

  List<LibraryRecord> _records(Object? raw) {
    return listOr(raw)
        .map((e) => LibraryRecord.fromJson(mapOr(e)))
        .where((e) => e.seriesKey.isNotEmpty)
        .toList(growable: false);
  }
}
