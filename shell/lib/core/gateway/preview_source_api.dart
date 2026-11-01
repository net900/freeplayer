import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../sp/models.dart';
import 'source_api.dart';

/// Debug-only fixture source used by the first-run "preview" entry. It never
/// ships as a user-visible source and is not reachable by the shell in tests
/// unless explicitly loaded (PRD §5.3 note).
class PreviewSourceApi implements SourceApi {
  PreviewSourceApi._({
    required this.manifest,
    required this.ui,
    required List<Item> items,
    required Map<String, List<Episode>> episodes,
    required MediaPlan plan,
  })  : _items = items,
        _episodes = episodes,
        _plan = plan;

  static const String assetPath = 'assets/dev/demo.json';

  final UIManifest ui;
  final List<Item> _items;
  final Map<String, List<Episode>> _episodes;
  final MediaPlan _plan;

  @override
  final SourceManifest manifest;

  @override
  String get sourceId => manifest.id;

  static Future<PreviewSourceApi> load() async {
    final raw = await rootBundle.loadString(assetPath);
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final episodes = <String, List<Episode>>{};
    mapOr(root['episodes']).forEach((key, value) {
      episodes[key] = listOr(value)
          .map((e) => Episode.fromJson(mapOr(e)))
          .toList(growable: false);
    });
    return PreviewSourceApi._(
      manifest: SourceManifest.fromJson(mapOr(root['source'])),
      ui: UIManifest.fromJson(mapOr(root['ui'])),
      items: listOr(root['items'])
          .map((e) => Item.fromJson(mapOr(e)))
          .toList(growable: false),
      episodes: episodes,
      plan: MediaPlan.fromJson(mapOr(root['plan'])),
    );
  }

  @override
  Future<ItemPage> search(
    String query, {
    String cursor = '',
    int limit = 20,
    int tabType = 0,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return const ItemPage();
    }
    final matched = _items
        .where((item) =>
            item.title.toLowerCase().contains(needle) ||
            item.description.toLowerCase().contains(needle))
        .toList(growable: false);
    return ItemPage(items: matched.take(limit).toList(growable: false));
  }

  @override
  Future<Item> detail(String itemId) async {
    for (final item in _items) {
      if (item.id == itemId) return item;
    }
    throw const SpException(SpErrorCode.notFound, 'item not found');
  }

  @override
  Future<EpisodePage> episodes(String itemId, {String cursor = ''}) async {
    return EpisodePage(episodes: _episodes[itemId] ?? const []);
  }

  @override
  Future<MediaPlan> play(PlayRequest request) async {
    return MediaPlan(
      itemId: request.itemId,
      episodeId: request.episodeId,
      streams: _plan.streams,
      decryption: _plan.decryption,
      expiresAt: _plan.expiresAt,
      nextEpisodeId: _plan.nextEpisodeId,
      downgraded: _plan.downgraded,
      extra: _plan.extra,
    );
  }

  @override
  Future<ItemPage> feed({String channel = '', String cursor = '', int limit = 20}) async =>
      ItemPage(items: _items);

  @override
  Future<ItemPage> rank({
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  }) async =>
      ItemPage(items: _items);

  @override
  Future<RankMeta> rankMeta({String type = '', String sub = ''}) async =>
      const RankMeta();

  @override
  Future<void> prefetchFeed({String channel = ''}) async {}

  @override
  Future<ItemPage> newItems({
    String gender = '2',
    String cursor = '',
    int limit = 20,
  }) async =>
      ItemPage(items: _items);

  @override
  Future<CalendarResult> calendar({String date = '', String cursor = ''}) async {
    final now = DateTime.now();
    String stamp(DateTime value) =>
        '${value.year}${value.month.toString().padLeft(2, '0')}'
        '${value.day.toString().padLeft(2, '0')}';
    final today = stamp(now);
    final dates = [
      for (var i = 0; i < 15; i++) stamp(now.add(Duration(days: i))),
    ];
    return CalendarResult(
      dates: dates,
      currentDate: today,
      defaultDate: today,
      targetDate: date.isEmpty ? today : date,
      items: _items,
    );
  }

  @override
  Future<ItemPage> category({
    String tag = '',
    String genre = '',
    String theme = '',
    String role = '',
    String epoch = '',
    String sort = '',
    String gender = '',
    String onlineTime = '',
    String cursor = '',
    int limit = 20,
  }) async =>
      ItemPage(items: _items);

  @override
  Future<List<Item>> hero() async => const <Item>[];

  @override
  Future<List<FilterGroup>> categoryMeta({String tag = ''}) async => const [];

  @override
  Future<List<HomeTab>> tabs() async => ui.homeTabs;

  @override
  Future<SuggestResult> suggest(String query, {int limit = 10}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const SuggestResult();
    return SuggestResult(
      words: _items
          .map((item) => item.title)
          .where((title) => title.toLowerCase().contains(needle))
          .take(limit)
          .toList(growable: false),
      items: _items
          .where((item) => item.title.toLowerCase().contains(needle))
          .take(limit)
          .toList(growable: false),
    );
  }

  @override
  Future<Map<String, ItemStats>> stats(List<String> itemIds, {String vid = ''}) async {
    return {
      for (final item in _items)
        if (itemIds.contains(item.id))
          item.id: ItemStats(
            episodeCount: item.extra['episode_cnt'] is num
                ? (item.extra['episode_cnt'] as num).toInt()
                : 0,
            playCount: item.extra['play_count'] is num
                ? (item.extra['play_count'] as num).toInt()
                : 0,
            categories: item.badges,
          ),
    };
  }

  @override
  Future<DanmakuPage> danmaku({
    required String itemId,
    required String episodeId,
    int durationSec = 0,
    int offsetSec = 0,
  }) async {
    return const DanmakuPage(
      source: 'preview',
      items: [
        DanmakuLine(time: 1, text: '预览弹幕', color: '#FFFFFF'),
        DanmakuLine(time: 3, text: '这是 demo 数据', color: '#FFD666'),
      ],
    );
  }

  @override
  Future<String> sendDanmaku({
    required String itemId,
    required String episodeId,
    required String text,
    int offsetSec = 0,
  }) async =>
      'preview-danmaku';

  @override
  @override
  Future<CommentPage> replies({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String commentId,
    String cursor = '',
    int limit = 20,
  }) async =>
      const CommentPage();

  @override
  Future<CommentPage> comments({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    String cursor = '',
    int limit = 20,
  }) async =>
      const CommentPage();

  @override
  Future<String> addComment({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) async =>
      'preview-comment';

  @override
  Future<String> replyComment({
    required String itemId,
    required String commentId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) async =>
      'preview-reply';

  @override
  Future<void> deleteComment(String commentId, {String kind = 'comment'}) async {}

  @override
  Future<void> likeComment(
    String commentId, {
    String kind = 'comment',
    bool liked = true,
    String itemId = '',
    String episodeId = '',
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> emoticons() async => const [];

  @override
  Future<void> setLike(String itemId, bool liked, {String episodeId = ''}) async {}

  @override
  Future<void> setFavorite(String itemId, bool favorite) async {}

  @override
  Future<void> setReservation(String itemId, bool reserve) async {}

  @override
  Future<void> setFollow(String itemId, bool followed) async {}

  @override
  Future<LoginQr> loginQrCode() async =>
      const LoginQr(token: 'preview', image: '');

  @override
  Future<LoginStatus> loginQrStatus(String token) async =>
      const LoginStatus(status: 'new');

  @override
  Future<AccountUser> account() async => const AccountUser();

  @override
  Future<Map<String, dynamic>> loginWith(
    String method,
    Map<String, String> fields,
  ) async =>
      {'logged_in': true, 'name': fields['username'] ?? '示例用户'};

  @override
  Future<void> logout() async {}

  @override
  Future<Map<String, dynamic>> sendSmsCode(String mobile) async =>
      const {'mobile_ticket': 'preview', 'retry_time': 60};

  Future<AccountUser> smsLogin({
    required String mobile,
    required String code,
  }) async =>
      const AccountUser();

  @override
  Future<ItemPage> favorites({String cursor = '', int limit = 20}) async =>
      ItemPage(items: _items);

  @override
  Future<ItemPage> history({String cursor = '', int limit = 20}) async =>
      ItemPage(items: _items);

  @override
  Future<ItemPage> follows({String cursor = '', int limit = 20}) async =>
      ItemPage(items: _items);

  @override
  Future<ItemPage> reservations({
    String cursor = '',
    int limit = 20,
    bool? online,
  }) async =>
      ItemPage(items: _items);

  @override
  Future<void> deleteReservations(List<String> itemIds, {bool online = false}) async {}

  @override
  Future<ItemPage> likes({String cursor = '', int limit = 20}) async =>
      ItemPage(items: _items);

  @override
  Future<ItemPage> album(String itemId, {String albumId = ''}) async =>
      const ItemPage();

  @override
  Future<ItemPage> related(
    String itemId, {
    String scene = '10',
    String from = 'detail_page_more_related',
    int limit = 20,
  }) async =>
      const ItemPage();

  @override
  Future<Map<String, dynamic>> progress(String itemId) async => const {};

  @override
  Future<void> saveProgress({
    required String itemId,
    required String episodeId,
    int index = 0,
    required int positionSec,
    required int durationSec,
  }) async {}

  @override
  @override
  Future<List<Map<String, dynamic>>> endpoints() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<String> shareLink({String itemId = '', String episodeId = ''}) async =>
      '';
}
