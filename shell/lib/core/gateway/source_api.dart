import '../sp/models.dart';

/// The only data surface the shell knows. Implementations are a remote gateway
/// or the debug-only preview fixture. No source logic lives here (PRD §5.2).
/// Implemented by sources that own in-process resources (for example an
/// embedded JS runtime). The shell closes it when the source is removed.
abstract class ClosableSourceApi {
  void close();
}

abstract class SourceApi {
  String get sourceId;

  SourceManifest get manifest;

  Future<ItemPage> search(
    String query, {
    String cursor = '',
    int limit = 20,
    int tabType = 0,
  });

  Future<Item> detail(String itemId);

  Future<EpisodePage> episodes(String itemId, {String cursor = ''});

  Future<MediaPlan> play(PlayRequest request);

  // Gateway extensions (PRD §9.2). Sources may answer 50100; the shell then
  // shows an unsupported state instead of failing the page.
  Future<ItemPage> feed({String channel = '', String cursor = '', int limit = 20});

  /// New three-level ranking: [type] selected_items, [sub] sub_selected_items,
  /// [panel] panel_selected_items (受众/主题), [time] background_selected_items.
  /// [filter] is the legacy alias for type.
  Future<ItemPage> rank({
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  });

  /// The board selector plus that board's gender/theme panel rows
  /// (`panel_0`, `panel_1`, ...), which differ per [type]/[sub].
  Future<RankMeta> rankMeta({String type = '', String sub = ''});

  /// Warms the next first page for a home tab (fire and forget).
  Future<void> prefetchFeed({String channel = ''});

  /// gender: '2' 全部, '1' 男频, '0' 女频.
  Future<ItemPage> newItems({
    String gender = '2',
    String cursor = '',
    int limit = 20,
  });

  /// 上新日历 for one YYYYMMDD date (empty = backend's current date).
  /// [cursor] pages the same day's releases.
  Future<CalendarResult> calendar({String date = '', String cursor = ''});

  /// Structured category page (landpage select_items).
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
  });

  /// Filter groups for one category id (`tag`). Empty on home.
  Future<List<FilterGroup>> categoryMeta({String tag = ''});

  /// Editorial hero cards for the home page (wide artwork). Sources without a
  /// banner feed return an empty list and the shell falls back to the first
  /// catalogue items.
  Future<List<Item>> hero() async => const <Item>[];

  // In-page home navigation supplied by the source.
  Future<List<HomeTab>> tabs();

  // Search completions plus the dramas they point at.
  Future<SuggestResult> suggest(String query, {int limit = 10});

  // Counts and season metadata for the home overlay.
  Future<Map<String, ItemStats>> stats(List<String> itemIds, {String vid = ''});

  // Bullet lines for one episode (requires login).
  Future<DanmakuPage> danmaku({
    required String itemId,
    required String episodeId,
    int durationSec = 0,
    int offsetSec = 0,
  });

  Future<String> sendDanmaku({
    required String itemId,
    required String episodeId,
    required String text,
    int offsetSec = 0,
  });

  Future<CommentPage> replies({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String commentId,
    String cursor = '',
    int limit = 20,
  });

  Future<CommentPage> comments({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    String cursor = '',
    int limit = 20,
  });

  Future<String> addComment({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  });

  Future<String> replyComment({
    required String itemId,
    required String commentId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  });

  Future<void> deleteComment(String commentId, {String kind = 'comment'});

  Future<void> likeComment(
    String commentId, {
    String kind = 'comment',
    bool liked = true,
    String itemId = '',
    String episodeId = '',
  });

  Future<List<Map<String, dynamic>>> emoticons();

  Future<void> setLike(String itemId, bool liked, {String episodeId = ''});

  Future<void> setFavorite(String itemId, bool favorite);

  Future<void> setReservation(String itemId, bool reserve);

  Future<void> setFollow(String itemId, bool followed);

  // ---------------------------------------------------------------- account

  Future<LoginQr> loginQrCode();

  Future<LoginStatus> loginQrStatus(String token);

  Future<Map<String, dynamic>> sendSmsCode(String mobile);

  Future<AccountUser> smsLogin({
    required String mobile,
    required String code,
  });

  Future<AccountUser> account();

  /// Generic, source-defined login. The gateway keeps the credential; the
  /// returned map is whatever display payload the source chose to expose.
  Future<Map<String, dynamic>> loginWith(
    String method,
    Map<String, String> fields,
  );

  Future<void> logout();

  Future<ItemPage> favorites({String cursor = '', int limit = 20});

  Future<ItemPage> history({String cursor = '', int limit = 20});

  Future<ItemPage> follows({String cursor = '', int limit = 20});

  Future<ItemPage> reservations({
    String cursor = '',
    int limit = 20,
    bool? online,
  });

  Future<void> deleteReservations(List<String> itemIds, {bool online = false});

  Future<ItemPage> likes({String cursor = '', int limit = 20});

  /// 作品系列 / 合集 of one drama; empty when it has none.
  Future<ItemPage> album(String itemId, {String albumId = ''});

  /// Related works / other seasons, supplied by the source.
  Future<ItemPage> related(
    String itemId, {
    String scene = '10',
    String from = 'detail_page_more_related',
    int limit = 20,
  });

  Future<Map<String, dynamic>> progress(String itemId);

  Future<void> saveProgress({
    required String itemId,
    required String episodeId,
    int index = 0,
    required int positionSec,
    required int durationSec,
  });

  Future<String> shareLink({String itemId = '', String episodeId = ''});

  /// Static endpoint registry of the source (diagnostics).
  Future<List<Map<String, dynamic>>> endpoints();
}
