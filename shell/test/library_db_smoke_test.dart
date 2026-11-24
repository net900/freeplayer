import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/storage/library_db.dart';

void main() {
  test(
    'library db stores history, resume points and favorites',
    () {
      final dir = Directory.systemTemp.createTempSync('fp_library_db');
      final db = LibraryDb.open(
        '${dir.path}${Platform.pathSeparator}library.db',
      );
      expect(db, isNotNull);
      final database = db!;
      addTearDown(() {
        database.close();
        dir.deleteSync(recursive: true);
      });

      final record = <String, dynamic>{
        'series_key': 'src:1',
        'title': '测试剧',
        'cover': '',
        'source_id': 'src',
        'item_id': '1',
        'episode_id': 'ep3',
        'episode_index': 3,
        'position_sec': 100,
        'duration_sec': 200,
        'updated_at': '2026-01-01T00:00:00Z',
        'episode_count': 10,
        'finished': false,
        'category': '',
      };
      database.recordProgress(record);
      database.recordEpisodePosition(
        'src:1',
        'ep3',
        positionSec: 100,
        durationSec: 200,
      );

      expect(database.history().single['title'], '测试剧');
      expect(database.episodeResume('src:1', 'ep3'), 100);

      final finished = <String, dynamic>{
        ...record,
        'position_sec': 200,
        'finished': true,
      };
      database.recordPlayback(
        finished,
        resumePositionSec: 0,
        resumeDurationSec: 200,
        completed: true,
      );

      // Finished: no resume, but still marked watched.
      expect(database.episodeResume('src:1', 'ep3'), 0);
      expect(database.episodePositions('src:1')['ep3'], 200);

      database.toggleFavorite(record);
      expect(database.isFavorite('src:1'), isTrue);
      database.setPlaybackRate(1.5);
      expect(database.playbackRate(), 1.5);
    },
    skip: !Platform.isWindows,
  );
}
