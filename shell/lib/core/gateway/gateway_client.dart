import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sp/models.dart';
import 'source_api.dart';

/// HTTP client for SourceProtocol v1. It only understands the protocol
/// envelope, never a specific source (PRD §6.3).
class GatewayClient {
  GatewayClient({
    required String baseUrl,
    required this.clientId,
    this.timeout = const Duration(seconds: 15),
    HttpClient? httpClient,
  })  : base = Uri.parse(baseUrl),
        _http = httpClient ?? HttpClient();

  final Uri base;
  final String clientId;
  final Duration timeout;
  final HttpClient _http;

  /// source id -> logical action -> path template. Set from the manifest so a
  /// source can use any path (including absolute URLs) instead of the
  /// shell's defaults.
  final Map<String, Map<String, String>> _routes = {};

  /// source id -> login credentials returned by /auth/login. Attached to
  /// every request for that source; cleared on logout.
  final Map<String, Map<String, String>> _credentials = {};

  void setRoutes(String sourceId, Map<String, String>? routes) {
    if (routes == null || routes.isEmpty) {
      _routes.remove(sourceId);
    } else {
      _routes[sourceId] = routes;
    }
  }

  void setCredentials(String sourceId, Map<String, String> credentials) {
    if (credentials.isEmpty) {
      _credentials.remove(sourceId);
    } else {
      _credentials[sourceId] = credentials;
    }
  }

  void clearCredentials(String sourceId) {
    _credentials.remove(sourceId);
  }

  /// Snapshot for a client that replaces this one (source switch): without it
  /// the new instance starts logged out.
  Map<String, Map<String, String>> get credentials =>
      {for (final entry in _credentials.entries) entry.key: {...entry.value}};

  void restoreCredentials(Map<String, Map<String, String>> saved) {
    for (final entry in saved.entries) {
      if (entry.value.isNotEmpty) _credentials[entry.key] = {...entry.value};
    }
  }

  Future<Map<String, dynamic>> meta() => _get('/v1/meta');

  Future<List<SourceManifest>> sources() async {
    // The address the user typed may itself be the source-list endpoint, e.g.
    // https://host/v1/xxx/sources_test.php. Only append the default path when
    // the address has no path of its own.
    final hasPath = base.path.isNotEmpty && base.path != '/';
    final data = hasPath
        ? await _getAbsolute(base)
        : await _get('/v1/sources');
    return listOr(data['sources'])
        .map((e) => SourceManifest.fromJson(mapOr(e)))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> uiJson(
    String sourceId, {
    required List<String> clientPages,
  }) {
    return _get(
      '/v1/${Uri.encodeComponent(sourceId)}/ui',
      headers: {'X-Client-Pages': clientPages.join(',')},
    );
  }

  Future<UIManifest> ui(String sourceId, {required List<String> clientPages}) async {
    return UIManifest.fromJson(
      await uiJson(sourceId, clientPages: clientPages),
    );
  }

  Future<ItemPage> search(
    String sourceId,
    String query, {
    String cursor = '',
    int limit = 20,
    int tabType = 0,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/search',
      query: {
        'q': query,
        if (cursor.isNotEmpty) 'cursor': cursor,
        if (tabType > 0) 'tab_type': '$tabType',
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<Item> detail(String sourceId, String itemId) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/detail/${Uri.encodeComponent(itemId)}',
    );
    return Item.fromJson(data);
  }

  Future<EpisodePage> episodes(
    String sourceId,
    String itemId, {
    String cursor = '',
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/episodes/${Uri.encodeComponent(itemId)}',
      query: {if (cursor.isNotEmpty) 'cursor': cursor},
    );
    return EpisodePage.fromJson(data);
  }

  Future<MediaPlan> play(String sourceId, PlayRequest request) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/play',
      request.toJson(),
    );
    return MediaPlan.fromJson(data);
  }

  Future<ItemPage> feed(
    String sourceId, {
    String channel = '',
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/feed',
      query: {
        if (channel.isNotEmpty) 'channel': channel,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> rank(
    String sourceId, {
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/rank',
      query: {
        if (type.isNotEmpty) 'type': type,
        if (filter.isNotEmpty) 'filter': filter,
        if (sub.isNotEmpty) 'sub': sub,
        if (panel.isNotEmpty) 'panel': panel,
        if (time.isNotEmpty) 'time': time,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<void> prefetchFeed(String sourceId, {String channel = ''}) async {
    await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/prefetch',
      query: {if (channel.isNotEmpty) 'channel': channel},
    );
  }

  Future<RankMeta> rankMeta(
    String sourceId, {
    String type = '',
    String sub = '',
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/rank/meta',
      query: {
        if (type.isNotEmpty) 'type': type,
        if (sub.isNotEmpty) 'sub': sub,
      },
    );
    return RankMeta.fromJson(data);
  }

  Future<ItemPage> newItems(
    String sourceId, {
    String gender = '2',
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/new',
      query: {
        if (gender.isNotEmpty) 'gender': gender,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<CalendarResult> calendar(
    String sourceId, {
    String date = '',
    String cursor = '',
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/calendar',
      query: {
        if (date.isNotEmpty) 'date': date,
        if (cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    return CalendarResult.fromJson(data);
  }

  Future<ItemPage> category(
    String sourceId, {
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
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/category',
      query: {
        if (tag.isNotEmpty) 'tag': tag,
        if (genre.isNotEmpty) 'genre': genre,
        if (theme.isNotEmpty) 'theme': theme,
        if (role.isNotEmpty) 'role': role,
        if (epoch.isNotEmpty) 'epoch': epoch,
        if (sort.isNotEmpty) 'sort': sort,
        if (gender.isNotEmpty) 'gender': gender,
        if (onlineTime.isNotEmpty) 'online_time': onlineTime,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<List<FilterGroup>> categoryMeta(String sourceId, [String tag = '']) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/category/meta'
      '${tag.isEmpty ? '' : '?type=${Uri.encodeComponent(tag)}'}',
    );
    return listOr(data['groups'])
        .map((e) => FilterGroup.fromJson(mapOr(e)))
        .toList(growable: false);
  }

  Future<List<HomeTab>> tabs(String sourceId) async {
    final data = await _get('/v1/${Uri.encodeComponent(sourceId)}/tabs');
    return listOr(data['tabs'])
        .map((e) => HomeTab.fromJson(mapOr(e)))
        .toList(growable: false);
  }

  Future<SuggestResult> suggest(
    String sourceId,
    String query, {
    int limit = 10,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/suggest',
      query: {'q': query, 'limit': '$limit'},
    );
    return SuggestResult.fromJson(data);
  }

  Future<Map<String, ItemStats>> stats(
    String sourceId,
    List<String> itemIds, {
    String vid = '',
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/stats',
      query: {
        'ids': itemIds.join(','),
        if (vid.isNotEmpty) 'vid': vid,
      },
    );
    final out = <String, ItemStats>{};
    mapOr(data['stats']).forEach((key, value) {
      final stats = ItemStats.fromJson(value);
      if (stats != null) out[key] = stats;
    });
    return out;
  }

  Future<DanmakuPage> danmaku(
    String sourceId, {
    required String itemId,
    required String episodeId,
    int durationSec = 0,
    int offsetSec = 0,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/danmaku',
      query: {
        'item_id': itemId,
        'episode_id': episodeId,
        if (durationSec > 0) 'duration': '$durationSec',
        if (offsetSec > 0) 'offset': '$offsetSec',
      },
    );
    return DanmakuPage.fromJson(data);
  }

  Future<String> sendDanmaku(
    String sourceId, {
    required String itemId,
    required String episodeId,
    required String text,
    int offsetSec = 0,
  }) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/danmaku',
      {
        'item_id': itemId,
        'episode_id': episodeId,
        'kind': 'danmaku',
        'text': text,
        'offset_sec': offsetSec,
      },
    );
    return str(data['id']);
  }

  Future<CommentPage> replies(
    String sourceId, {
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String commentId,
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/comments/'
      '${Uri.encodeComponent(commentId)}/replies',
      query: {
        'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
        'kind': kind,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return CommentPage.fromJson(data);
  }

  Future<CommentPage> comments(
    String sourceId, {
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/comments',
      query: {
        'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
        'kind': kind,
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return CommentPage.fromJson(data);
  }

  Future<String> addComment(
    String sourceId, {
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/comments',
      {
        'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
        'kind': kind,
        'text': text,
        'offset_sec': offsetSec,
      },
    );
    return str(data['id']);
  }

  Future<String> replyComment(
    String sourceId, {
    required String itemId,
    required String commentId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/comments/${Uri.encodeComponent(commentId)}/reply',
      {
        'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
        'kind': kind,
        'text': text,
        'offset_sec': offsetSec,
      },
    );
    return str(data['id']);
  }

  Future<void> deleteComment(
    String sourceId,
    String commentId, {
    String kind = 'comment',
  }) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/comments/${Uri.encodeComponent(commentId)}/delete',
      {'kind': kind},
    );
  }

  Future<void> likeComment(
    String sourceId,
    String commentId, {
    String kind = 'comment',
    bool liked = true,
    String itemId = '',
    String episodeId = '',
  }) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/comments/${Uri.encodeComponent(commentId)}/like',
      {
        'kind': kind,
        'liked': liked,
        if (itemId.isNotEmpty) 'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
      },
    );
  }

  Future<List<Map<String, dynamic>>> emoticons(String sourceId) async {
    final data = await _get('/v1/${Uri.encodeComponent(sourceId)}/emoticons');
    return listOr(data['info_list'])
        .map((e) => mapOr(e))
        .toList(growable: false);
  }

  Future<void> deleteReservations(
    String sourceId,
    List<String> itemIds, {
    bool online = false,
  }) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/reservations/delete',
      {'item_ids': itemIds, 'online': online},
    );
  }

  Future<void> setLike(
    String sourceId,
    String itemId,
    bool liked, {
    String episodeId = '',
  }) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/like',
      {
        'item_id': itemId,
        if (episodeId.isNotEmpty) 'episode_id': episodeId,
        'liked': liked,
      },
    );
  }

  Future<void> setFavorite(String sourceId, String itemId, bool favorite) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/favorite',
      {'item_id': itemId, 'favorite': favorite},
    );
  }

  Future<void> setFollow(String sourceId, String itemId, bool followed) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/follow',
      {'item_id': itemId, 'followed': followed},
    );
  }

  Future<void> setReservation(
    String sourceId,
    String itemId,
    bool reserve,
  ) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/subscribe',
      {'item_id': itemId, 'reserve': reserve},
    );
  }

  Future<LoginQr> loginQrCode(String sourceId) async {
    final data = await _get('/v1/${Uri.encodeComponent(sourceId)}/auth/qrcode');
    return LoginQr.fromJson(data);
  }

  Future<LoginStatus> loginQrStatus(String sourceId, String token) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/auth/qrcode/status',
      query: {'token': token},
    );
    return LoginStatus.fromJson(data);
  }

  Future<AccountUser> account(String sourceId) async {
    final data = await _get('/v1/${Uri.encodeComponent(sourceId)}/auth/me');
    return AccountUser.fromJson(data);
  }

  Future<void> logout(String sourceId) async {
    await _post('/v1/${Uri.encodeComponent(sourceId)}/auth/logout', const {});
  }

  Future<Map<String, dynamic>> login(
    String sourceId, {
    required String method,
    required Map<String, String> fields,
  }) {
    return _post(
      '/v1/${Uri.encodeComponent(sourceId)}/auth/login',
      {'method': method, 'fields': fields},
    );
  }

  Future<Map<String, dynamic>> sendSmsCode(String sourceId, String mobile) {
    return _post(
      '/v1/${Uri.encodeComponent(sourceId)}/auth/sms/send',
      {'mobile': mobile},
    );
  }

  Future<AccountUser> smsLogin(
    String sourceId, {
    required String mobile,
    required String code,
  }) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/auth/sms/login',
      {'mobile': mobile, 'code': code},
    );
    return AccountUser.fromJson({...data, 'logged_in': true});
  }

  Future<ItemPage> favorites(
    String sourceId, {
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/favorites',
      query: {
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> history(
    String sourceId, {
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/history',
      query: {
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> follows(
    String sourceId, {
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/follows',
      query: {
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> reservations(
    String sourceId, {
    String cursor = '',
    int limit = 20,
    bool? online,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/reservations',
      query: {
        if (cursor.isNotEmpty) 'cursor': cursor,
        if (online != null) 'state': online ? 'online' : 'offline',
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> likes(
    String sourceId, {
    String cursor = '',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/likes',
      query: {
        if (cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> album(
    String sourceId,
    String itemId, {
    String albumId = '',
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/album/${Uri.encodeComponent(itemId)}',
      query: {if (albumId.isNotEmpty) 'album_id': albumId},
    );
    return ItemPage.fromJson(data);
  }

  Future<ItemPage> related(
    String sourceId,
    String itemId, {
    String scene = '10',
    String from = 'detail_page_more_related',
    int limit = 20,
  }) async {
    final data = await _get(
      '/v1/${Uri.encodeComponent(sourceId)}/plan',
      query: {
        'item_id': itemId,
        'scene': scene,
        'from': from,
        'limit': '$limit',
      },
    );
    return ItemPage.fromJson(data);
  }

  Future<Map<String, dynamic>> progress(String sourceId, String itemId) async {
    return _get(
      '/v1/${Uri.encodeComponent(sourceId)}/progress',
      query: {'item_id': itemId},
    );
  }

  Future<void> saveProgress(
    String sourceId, {
    required String itemId,
    required String episodeId,
    int index = 0,
    required int positionSec,
    required int durationSec,
  }) async {
    await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/progress',
      {
        'item_id': itemId,
        'episode_id': episodeId,
        'index': index,
        'position_sec': positionSec,
        'duration_sec': durationSec,
      },
    );
  }

  Future<String> shareLink(
    String sourceId, {
    String itemId = '',
    String episodeId = '',
  }) async {
    final data = await _post(
      '/v1/${Uri.encodeComponent(sourceId)}/share',
      {'item_id': itemId, 'episode_id': episodeId},
    );
    return str(data['url']);
  }

  Future<List<Map<String, dynamic>>> endpoints(String sourceId) async {
    final data = await _get('/v1/${Uri.encodeComponent(sourceId)}/endpoints');
    return listOr(data['endpoints'])
        .map((e) => mapOr(e))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) {
    return _request('GET', path, query: query, headers: headers);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) {
    return _request('POST', path, body: body, headers: headers);
  }

  Future<Map<String, dynamic>> _getAbsolute(Uri uri) => _send('GET', uri);

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
  }) {
    // Read the source id before route mapping: the final path may be a
    // source-defined URL that no longer contains /v1/<sid>/.
    final sourceId = _sourceIdFromPath(path);
    final uri = _resolve(_mapRoute(path), query);
    return _send(
      method,
      uri,
      sourceId: sourceId,
      headers: headers,
      body: body,
    );
  }

  /// One request, retried for reads when the connection itself fails.
  ///
  /// The gateway is reached over a link that drops connections now and then
  /// (measured 2026-11-01: two of four requests timed out on a healthy line).
  /// A single failure used to leave a page on 加载失败 until the user pressed
  /// 重试, so GETs are retried silently; writes are not, because a POST that
  /// already reached the server must not run twice.
  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    String? sourceId,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
  }) async {
    final attempts = method == 'GET' ? 3 : 1;
    for (var attempt = 0; ; attempt++) {
      try {
        return await _sendOnce(
          method,
          uri,
          sourceId: sourceId,
          headers: headers,
          body: body,
        );
      } on Object catch (error) {
        if (attempt + 1 >= attempts || !_isTransient(error)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  /// Failures worth retrying: the request never got an answer.
  static bool _isTransient(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HttpException;

  Future<Map<String, dynamic>> _sendOnce(
    String method,
    Uri uri, {
    String? sourceId,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
  }) async {
    final request = await _http.openUrl(method, uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set('X-Client-Id', clientId);
    request.headers.set('X-Source-Protocol', '1');
    _attachCredentials(request, sourceId);
    headers?.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }

    final response = await request.close().timeout(timeout);
    final bytes = await response.timeout(timeout).fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    final text = utf8.decode(bytes, allowMalformed: true);

    Map<String, dynamic> decoded = const {};
    if (text.trim().isEmpty && response.statusCode == 200) {
      // A proxy or a restarting gateway can answer 200 with nothing; treating
      // that as a valid empty payload once blanked the stored UI manifest.
      throw SpException(
        _statusToCode(response.statusCode),
        '地址返回了空响应',
      );
    }
    if (text.trim().isNotEmpty) {
      final Object? value;
      try {
        value = jsonDecode(text);
      } on FormatException {
        // A plain web page or an nginx error page landed here.
        throw SpException(
          _statusToCode(response.statusCode),
          response.statusCode >= 400
              ? '地址返回 HTTP ${response.statusCode}，不是接口数据'
              : '地址返回的不是接口数据',
        );
      }
      if (value is Map) {
        decoded = value.map((key, value) => MapEntry(key.toString(), value));
      }
    }

    final envelope = ApiEnvelope.fromJson(decoded);
    if (!envelope.ok) {
      throw SpException(
        envelope.code == 0 ? _statusToCode(response.statusCode) : envelope.code,
        envelope.message.isEmpty
            ? '地址返回 HTTP ${response.statusCode}'
            : envelope.message,
        traceId: envelope.traceId,
      );
    }
    if (response.statusCode >= 400) {
      throw SpException(
        _statusToCode(response.statusCode),
        '地址返回 HTTP ${response.statusCode}',
      );
    }
    final data = envelope.data;
    if (data is Map) {
      return mapOr(_absImages(data));
    }
    return mapOr(_absImages(decoded));
  }

  String? _sourceIdFromPath(String path) {
    final match = RegExp(r'^/v1/([^/]+)/').firstMatch(path);
    return match == null ? null : Uri.decodeComponent(match.group(1)!);
  }

  void _attachCredentials(HttpClientRequest request, String? sourceId) {
    if (sourceId == null) return;
    final creds = _credentials[sourceId];
    if (creds == null) return;

    final authorization = creds['authorization'] ?? '';
    if (authorization.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    } else {
      final token = creds['token'] ?? '';
      if (token.isNotEmpty) {
        final header = (creds['header'] ?? '').trim();
        final prefix = creds['prefix'] ?? 'Bearer ';
        if (header.isNotEmpty) {
          request.headers.set(header, '$prefix$token');
        } else {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $token',
          );
        }
      }
    }

    final cookie = creds['cookie'] ?? '';
    if (cookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    }
  }

  /// Rewrites a default action path through the source's manifest endpoint
  /// map. Unknown actions keep the default so old manifests still work.
  String _mapRoute(String path) {
    final match = RegExp(r'^/v1/([^/]+)/(.+)$').firstMatch(path);
    if (match == null) return path;
    final sourceId = Uri.decodeComponent(match.group(1)!);
    final routes = _routes[sourceId];
    if (routes == null) return path;
    final rest = match.group(2)!;
    final template = routes[_routeKey(rest)];
    if (template == null || template.isEmpty) return path;
    return _fillTemplate(template, sourceId, rest);
  }

  String _routeKey(String rest) {
    if (rest.startsWith('auth/qrcode/status')) return 'auth_qrcode_status';
    if (rest.startsWith('auth/qrcode')) return 'auth_qrcode';
    if (rest.startsWith('auth/sms/send')) return 'auth_sms_send';
    if (rest.startsWith('auth/sms/login')) return 'auth_sms_login';
    if (rest.startsWith('auth/login')) return 'auth_login';
    if (rest.startsWith('auth/me')) return 'auth_me';
    if (rest.startsWith('auth/logout')) return 'auth_logout';
    if (rest.startsWith('rank/meta')) return 'rank_meta';
    if (rest.startsWith('category/meta')) return 'category_meta';
    if (rest.startsWith('comments/') && rest.endsWith('/reply')) {
      return 'comments_reply';
    }
    if (rest.startsWith('comments/') && rest.endsWith('/like')) {
      return 'comments_like';
    }
    if (rest.startsWith('comments/') && rest.endsWith('/delete')) {
      return 'comments_delete';
    }
    if (rest.startsWith('reservations/delete')) return 'reservations_delete';
    return rest.split('/').first;
  }

  String _fillTemplate(String template, String sourceId, String rest) {
    final parts = rest.split('/');
    String? itemId;
    String? commentId;
    if (parts.length >= 2 &&
        (rest.startsWith('detail/') ||
            rest.startsWith('episodes/') ||
            rest.startsWith('album/'))) {
      itemId = Uri.decodeComponent(parts[1]);
    }
    if (rest.startsWith('comments/') && parts.length >= 2) {
      commentId = Uri.decodeComponent(parts[1]);
    }
    return template
        .replaceAll('{source_id}', Uri.encodeComponent(sourceId))
        .replaceAll('{sid}', Uri.encodeComponent(sourceId))
        .replaceAll('{item_id}', Uri.encodeComponent(itemId ?? ''))
        .replaceAll('{comment_id}', Uri.encodeComponent(commentId ?? ''))
        .replaceAll('{album_id}', Uri.encodeComponent(itemId ?? ''));
  }

  /// Source-relative image paths (the HEIC cover proxy) become absolute.
  Object? _absImages(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _absImageField(
            entry.key.toString(),
            entry.value,
          ),
      };
    }
    if (value is List) return value.map(_absImages).toList();
    return value;
  }

  Object? _absImageField(String key, Object? value) {
    final resolved = _absImages(value);
    if (resolved is String &&
        resolved.startsWith('/v1/') &&
        (key == 'cover' ||
            key == 'avatar' ||
            key == 'thumb_url' ||
            key == 'episode_cover')) {
      return '${base.scheme}://${base.authority}$resolved';
    }
    return resolved;
  }

  Uri _resolve(String path, Map<String, String>? query) {
    final Uri uri;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      uri = Uri.parse(path);
    } else {
      // A gateway can live under a path (`https://host/app`); dropping it
      // sent every route to the origin root and 404ed.
      final prefix = base.path.endsWith('/')
          ? base.path.substring(0, base.path.length - 1)
          : base.path;
      final relative = path.startsWith('/') ? path : '/$path';
      uri = Uri.parse('${base.scheme}://${base.authority}$prefix$relative');
    }
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      ...query,
    });
  }

  int _statusToCode(int status) {
    switch (status) {
      case 400:
        return SpErrorCode.badRequest;
      case 401:
        return SpErrorCode.unauthorized;
      case 403:
        return SpErrorCode.forbidden;
      case 404:
        return SpErrorCode.notFound;
      case 429:
        return SpErrorCode.rateLimited;
      default:
        return status >= 500 ? SpErrorCode.upstreamFailed : SpErrorCode.badRequest;
    }
  }

  void close() => _http.close(force: true);
}

/// Binds a [GatewayClient] to one source id and exposes the shell-side API.
class GatewaySourceApi implements SourceApi {
  GatewaySourceApi(this._client, this.manifest) {
    _client.setRoutes(manifest.id, manifest.endpoints);
  }

  final GatewayClient _client;

  // Filter panels are large and rarely change. Warm them once per session;
  // the category/rank pages then read the completed future instead of
  // hitting the gateway again.
  Future<List<FilterGroup>>? _categoryMetaCache;
  final Map<String, Future<RankMeta>> _rankMetaCache = {};

  @override
  final SourceManifest manifest;

  @override
  String get sourceId => manifest.id;

  @override
  Future<ItemPage> search(
    String query, {
    String cursor = '',
    int limit = 20,
    int tabType = 0,
  }) =>
      _client.search(sourceId, query,
          cursor: cursor, limit: limit, tabType: tabType);

  @override
  Future<Item> detail(String itemId) => _client.detail(sourceId, itemId);

  @override
  Future<EpisodePage> episodes(String itemId, {String cursor = ''}) =>
      _client.episodes(sourceId, itemId, cursor: cursor);

  @override
  Future<MediaPlan> play(PlayRequest request) => _client.play(sourceId, request);

  @override
  Future<ItemPage> feed({String channel = '', String cursor = '', int limit = 20}) =>
      _client.feed(sourceId, channel: channel, cursor: cursor, limit: limit);

  @override
  Future<ItemPage> rank({
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  }) =>
      _client.rank(
        sourceId,
        type: type,
        sub: sub,
        panel: panel,
        time: time,
        filter: filter,
        cursor: cursor,
        limit: limit,
      );

  @override
  Future<RankMeta> rankMeta({String type = '', String sub = ''}) {
    final key = '$type|$sub';
    final cached = _rankMetaCache[key];
    if (cached != null) return cached;
    final future = _client.rankMeta(sourceId, type: type, sub: sub);
    final guarded = future.then(
      (value) {
        if (value.groups.isEmpty) _rankMetaCache.remove(key);
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        _rankMetaCache.remove(key);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _rankMetaCache[key] = guarded;
    return guarded;
  }

  @override
  Future<void> prefetchFeed({String channel = ''}) async {
    // Best-effort warm-up: a failed prefetch must never surface as an error.
    try {
      await _client.prefetchFeed(sourceId, channel: channel);
    } on Object {
      // ignored
    }
  }

  @override
  Future<ItemPage> newItems({
    String gender = '2',
    String cursor = '',
    int limit = 20,
  }) =>
      _client.newItems(
        sourceId,
        gender: gender,
        cursor: cursor,
        limit: limit,
      );

  @override
  Future<CalendarResult> calendar({String date = '', String cursor = ''}) =>
      _client.calendar(sourceId, date: date, cursor: cursor);

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
  }) =>
      _client.category(
        sourceId,
        tag: tag,
        genre: genre,
        theme: theme,
        role: role,
        epoch: epoch,
        sort: sort,
        gender: gender,
        onlineTime: onlineTime,
        cursor: cursor,
        limit: limit,
      );

  @override
  Future<List<Item>> hero() async => const <Item>[];

  @override
  Future<List<FilterGroup>> categoryMeta({String tag = ''}) {
    if (tag.isNotEmpty) return _client.categoryMeta(sourceId, tag);
    final cached = _categoryMetaCache;
    if (cached != null) return cached;
    final future = _client.categoryMeta(sourceId);
    final guarded = future.then(
      (groups) {
        if (groups.isEmpty) _categoryMetaCache = null;
        return groups;
      },
      onError: (Object error, StackTrace stackTrace) {
        _categoryMetaCache = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _categoryMetaCache = guarded;
    return guarded;
  }

  @override
  Future<List<HomeTab>> tabs() => _client.tabs(sourceId);

  @override
  Future<SuggestResult> suggest(String query, {int limit = 10}) =>
      _client.suggest(sourceId, query, limit: limit);

  @override
  Future<Map<String, ItemStats>> stats(List<String> itemIds, {String vid = ''}) =>
      _client.stats(sourceId, itemIds, vid: vid);

  @override
  Future<DanmakuPage> danmaku({
    required String itemId,
    required String episodeId,
    int durationSec = 0,
    int offsetSec = 0,
  }) =>
      _client.danmaku(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        durationSec: durationSec,
        offsetSec: offsetSec,
      );

  @override
  Future<String> sendDanmaku({
    required String itemId,
    required String episodeId,
    required String text,
    int offsetSec = 0,
  }) =>
      _client.sendDanmaku(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        text: text,
        offsetSec: offsetSec,
      );

  @override
  @override
  Future<CommentPage> replies({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String commentId,
    String cursor = '',
    int limit = 20,
  }) =>
      _client.replies(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        kind: kind,
        commentId: commentId,
        cursor: cursor,
        limit: limit,
      );

  @override
  Future<CommentPage> comments({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    String cursor = '',
    int limit = 20,
  }) =>
      _client.comments(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        kind: kind,
        cursor: cursor,
        limit: limit,
      );

  @override
  Future<String> addComment({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) =>
      _client.addComment(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        kind: kind,
        text: text,
        offsetSec: offsetSec,
      );

  @override
  Future<String> replyComment({
    required String itemId,
    required String commentId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) =>
      _client.replyComment(
        sourceId,
        itemId: itemId,
        commentId: commentId,
        episodeId: episodeId,
        kind: kind,
        text: text,
        offsetSec: offsetSec,
      );

  @override
  Future<void> deleteComment(String commentId, {String kind = 'comment'}) =>
      _client.deleteComment(sourceId, commentId, kind: kind);

  @override
  Future<void> likeComment(
    String commentId, {
    String kind = 'comment',
    bool liked = true,
    String itemId = '',
    String episodeId = '',
  }) =>
      _client.likeComment(
        sourceId,
        commentId,
        kind: kind,
        liked: liked,
        itemId: itemId,
        episodeId: episodeId,
      );

  @override
  Future<List<Map<String, dynamic>>> emoticons() => _client.emoticons(sourceId);

  @override
  Future<void> setLike(String itemId, bool liked, {String episodeId = ''}) =>
      _client.setLike(sourceId, itemId, liked, episodeId: episodeId);

  @override
  Future<void> setFavorite(String itemId, bool favorite) =>
      _client.setFavorite(sourceId, itemId, favorite);

  @override
  Future<void> setReservation(String itemId, bool reserve) =>
      _client.setReservation(sourceId, itemId, reserve);

  @override
  Future<void> setFollow(String itemId, bool followed) =>
      _client.setFollow(sourceId, itemId, followed);

  @override
  Future<LoginQr> loginQrCode() => _client.loginQrCode(sourceId);

  @override
  Future<LoginStatus> loginQrStatus(String token) =>
      _client.loginQrStatus(sourceId, token);

  @override
  Future<AccountUser> account() => _client.account(sourceId);

  @override
  Future<Map<String, dynamic>> loginWith(
    String method,
    Map<String, String> fields,
  ) async {
    final result = await _client.login(
      sourceId,
      method: method,
      fields: fields,
    );
    final raw = mapOr(result['credentials']);
    if (raw.isNotEmpty) {
      final creds = <String, String>{
        for (final entry in raw.entries)
          entry.key.toString(): entry.value?.toString() ?? '',
      };
      final auth = manifest.auth;
      if (auth != null) {
        if ((creds['header'] ?? '').isEmpty &&
            auth.credentialHeader.isNotEmpty) {
          creds['header'] = auth.credentialHeader;
        }
        if ((creds['prefix'] ?? '').isEmpty &&
            auth.credentialPrefix.isNotEmpty) {
          creds['prefix'] = auth.credentialPrefix;
        }
      }
      _client.setCredentials(sourceId, creds);
    }
    return result;
  }

  @override
  Future<void> logout() {
    _client.clearCredentials(sourceId);
    return _client.logout(sourceId);
  }

  @override
  Future<Map<String, dynamic>> sendSmsCode(String mobile) =>
      _client.sendSmsCode(sourceId, mobile);

  Future<AccountUser> smsLogin({
    required String mobile,
    required String code,
  }) =>
      _client.smsLogin(sourceId, mobile: mobile, code: code);

  @override
  Future<ItemPage> favorites({String cursor = '', int limit = 20}) =>
      _client.favorites(sourceId, cursor: cursor, limit: limit);

  @override
  Future<ItemPage> history({String cursor = '', int limit = 20}) =>
      _client.history(sourceId, cursor: cursor, limit: limit);

  @override
  Future<ItemPage> follows({String cursor = '', int limit = 20}) =>
      _client.follows(sourceId, cursor: cursor, limit: limit);

  @override
  Future<ItemPage> reservations({
    String cursor = '',
    int limit = 20,
    bool? online,
  }) =>
      _client.reservations(sourceId,
          cursor: cursor, limit: limit, online: online);

  @override
  Future<void> deleteReservations(List<String> itemIds, {bool online = false}) =>
      _client.deleteReservations(sourceId, itemIds, online: online);

  @override
  Future<ItemPage> likes({String cursor = '', int limit = 20}) =>
      _client.likes(sourceId, cursor: cursor, limit: limit);

  @override
  Future<ItemPage> album(String itemId, {String albumId = ''}) =>
      _client.album(sourceId, itemId, albumId: albumId);

  @override
  Future<ItemPage> related(
    String itemId, {
    String scene = '10',
    String from = 'detail_page_more_related',
    int limit = 20,
  }) =>
      _client.related(sourceId, itemId,
          scene: scene, from: from, limit: limit);

  @override
  Future<Map<String, dynamic>> progress(String itemId) =>
      _client.progress(sourceId, itemId);

  @override
  Future<void> saveProgress({
    required String itemId,
    required String episodeId,
    int index = 0,
    required int positionSec,
    required int durationSec,
  }) =>
      _client.saveProgress(
        sourceId,
        itemId: itemId,
        episodeId: episodeId,
        index: index,
        positionSec: positionSec,
        durationSec: durationSec,
      );

  @override
  Future<String> shareLink({String itemId = '', String episodeId = ''}) =>
      _client.shareLink(sourceId, itemId: itemId, episodeId: episodeId);

  @override
  Future<List<Map<String, dynamic>>> endpoints() => _client.endpoints(sourceId);
}
