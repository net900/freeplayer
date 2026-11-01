import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../gateway/source_api.dart';
import '../sp/quality.dart';
import '../library/local_library.dart';
import '../sp/models.dart';
import 'player_page.dart';

/// Resumes one history record. When the player closes because the user asked
/// for the detail page, the caller receives the work and its poster so it can
/// open the detail in its own (nested) navigator.
Future<({Item item, String poster})?> resumeLibraryRecord(
  BuildContext context,
  SourceApi api,
  LibraryRecord record,
) async {
  if (record.itemId.isEmpty) {
    throw const SpException(SpErrorCode.badRequest, '这条记录没有作品信息');
  }
  var episodeId = record.episodeId;
  var episodes = const <Episode>[];
  try {
    final page = await api.episodes(record.itemId);
    episodes = page.episodes;
    if (episodeId.isEmpty && episodes.isNotEmpty) {
      episodeId = episodes.first.id;
    }
  } on Object {
    // The player can still open a single stream without the rail.
  }
  if (episodeId.isEmpty) {
    throw const SpException(SpErrorCode.badRequest, '这条记录还没有可播放的剧集');
  }
  final quality = AppScope.controllerOf(context).settings.defaultQuality;
  final plan = await api.play(
    PlayRequest(
      itemId: record.itemId,
      episodeId: episodeId,
      quality: quality == Quality.auto ? 'auto' : quality,
    ),
  );
  if (!context.mounted) return null;
  final exit = await openFullPlayer(
    context,
    plan: plan,
    title: record.title,
    api: api,
    itemId: record.itemId,
    episodes: episodes,
    episodeId: episodeId,
    cover: record.cover,
  );
  if (!context.mounted || exit == null || !exit.wantsDetail) return null;
  try {
    final item = await api.detail(exit.itemId);
    return (item: item, poster: exit.cover);
  } on Object {
    return null;
  }
}
