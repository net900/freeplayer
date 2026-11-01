import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../gateway/source_api.dart';
import '../sp/models.dart';
import 'local_hls_proxy.dart';
import 'local_js_worker.dart';

/// A source packaged as JavaScript and executed by the client's embedded
/// QuickJS runtime. Dart owns HTTP, playlist validation and the local HLS
/// proxy; the JS package only builds URLs and parses upstream responses.
class LocalJsSourceApi implements SourceApi, ClosableSourceApi {
  LocalJsSourceApi._(
    this._worker,
    String upstream,
    Map<String, String> headers,
    this._dynamicHeaders,
    this.directMedia,
    this._hasHero,
    this._hasSuggest,
    this.manifest,
    this.ui,
  )   : _upstream = upstream,
        _headers = headers;

  /// Owns the package's QuickJS runtime on its own isolate: evaluating a
  /// local source is synchronous, and doing it here blocked the UI whenever a
  /// page fired a burst of play requests.
  final LocalJsWorker _worker;
  @override
  final SourceManifest manifest;
  final UIManifest ui;

  final String _upstream;

  /// Static headers declared as an object. Unused when [_dynamicHeaders].
  final Map<String, String> _headers;

  /// True when the package exports `headers` as a function. The shell then
  /// evaluates it per request so the package can sign the exact URL it just
  /// generated (fresh nonce/timestamp, query-bound signature).
  final bool _dynamicHeaders;

  /// True when the package declares `direct_media`. The player then receives
  /// the upstream playlist URL itself instead of the loopback HLS proxy.
  final bool directMedia;

  /// True when the package exposes `urls.hero` + `parseHero`.
  final bool _hasHero;

  /// True when the package exposes `urls.suggest` + `parseSuggest`.
  final bool _hasSuggest;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);
  final Map<String, Map<String, dynamic>> _detailCache = {};
  final Map<String, List<FilterGroup>> _filterCache = {};

  @override
  String get sourceId => manifest.id;

  static Future<LocalJsSourceApi> loadFile(String path) async {
    return loadSource(await File(path).readAsString());
  }

  static Future<LocalJsSourceApi> loadSource(String source) async {
    final worker = await LocalJsWorker.start(source);
    try {
      final decoded = jsonDecode(worker.meta);
      if (decoded is! Map) {
        throw const SpException(SpErrorCode.upstreamFailed, '本地源缺少 __FP_SOURCE');
      }
      final meta = Map<String, dynamic>.from(decoded);
      if (str(meta['id']).isEmpty || str(meta['name']).isEmpty) {
        throw const SpException(SpErrorCode.upstreamFailed, '本地源缺少 id 或名称');
      }
      final manifest = SourceManifest.fromJson({
        'id': str(meta['id']),
        'name': str(meta['name']),
        'version': str(meta['version']),
        'protocol': '1',
        'description': str(meta['description']),
        'icon': str(meta['icon']),
        'brand': meta['brand'],
        'capabilities': meta['capabilities'],
        'auth': const {'required': false, 'methods': <String>[]},
        'endpoints': const <String, String>{},
      });
      final ui = UIManifest.fromJson(mapOr(meta['ui']));
      final headers = <String, String>{
        for (final entry in mapOr(meta['headers']).entries)
          entry.key: entry.value?.toString() ?? '',
      };
      return LocalJsSourceApi._(
        worker,
        str(meta['upstream']),
        headers,
        worker.dynamicHeaders,
        meta['direct_media'] == true,
        worker.hasHero,
        worker.hasSuggest,
        manifest,
        ui,
      );
    } on Object {
      worker.close();
      rethrow;
    }
  }

  Future<String> _eval(String expression) async {
    final result = await _worker.evaluate(expression);
    if (result.failed) {
      throw SpException(SpErrorCode.upstreamFailed, result.error);
    }
    return result.value;
  }

  Future<dynamic> _json(String expression) async {
    final raw = await _eval('JSON.stringify($expression)');
    if (raw == 'undefined') return null;
    return jsonDecode(raw);
  }

  Future<Map<String, dynamic>?> _callOrNull(
    String name,
    List<Object?> args,
  ) async {
    final encoded = args.map(jsonEncode).join(',');
    final value = await _json('__FP_SOURCE.$name($encoded)');
    if (value == null) return null;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const SpException(SpErrorCode.upstreamFailed, '本地源返回了无效数据');
  }

  Future<Map<String, dynamic>> _call(String name, List<Object?> args) async {
    final value = await _callOrNull(name, args);
    if (value == null) {
      throw const SpException(SpErrorCode.upstreamFailed, '本地源没有返回数据');
    }
    return value;
  }

  Future<String> _url(String name, Map<String, Object?> context) async {
    final value = await _json('__FP_SOURCE.urls.$name(${jsonEncode(context)})');
    if (value is! String || value.isEmpty) {
      throw SpException(SpErrorCode.notFound, '本地源没有生成 $name 地址');
    }
    final uri = Uri.tryParse(_upstream);
    if (uri == null || uri.host.isEmpty) {
      throw const SpException(SpErrorCode.upstreamFailed, '本地源没有配置上游地址');
    }
    return uri.resolve(value).toString();
  }

  /// Headers used for playlist and segment hosts.
  ///
  /// Dynamic signatures are bound to the API query that produced them, so a
  /// package that signs requests never has its API headers forwarded to a CDN.
  Map<String, String> get _mediaHeaders =>
      _dynamicHeaders ? const <String, String>{} : _headers;

  /// Resolves the headers for one upstream request.
  ///
  /// Static packages use the map declared at load time. Dynamic packages are
  /// called with the final absolute URL so they can sign precisely the query
  /// that is about to be sent.
  Future<Map<String, String>> _requestHeaders(
    String name,
    String url,
    String method,
  ) async {
    if (!_dynamicHeaders) return _headers;
    final context = jsonEncode({
      'name': name,
      'url': url,
      'method': method,
    });
    final value = await _json('__FP_SOURCE.headers($context)');
    if (value is! Map) {
      throw const SpException(SpErrorCode.upstreamFailed, '本地源没有生成请求头');
    }
    final headers = <String, String>{};
    for (final entry in Map<String, dynamic>.from(value).entries) {
      final item = entry.value;
      if (item == null) continue;
      headers[entry.key] = item.toString();
    }
    return headers;
  }

  Future<String> _fetchText(
    String url, {
    String name = '',
    String method = 'GET',
    Map<String, String>? headersOverride,
  }) async {
    final request = await _http.getUrl(Uri.parse(url));
    final headers = headersOverride ?? await _requestHeaders(name, url, method);
    headers.forEach(request.headers.set);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'text/html,application/json,*/*')
      ..set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final builder = await response.fold<BytesBuilder>(BytesBuilder(copy: false),
        (builder, chunk) {
      builder.add(chunk);
      return builder;
    }).timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw SpException(
        SpErrorCode.upstreamFailed,
        '上游返回 ${response.statusCode}',
      );
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<ItemPage> _list(
    String url,
    Map<String, Object?> context,
    String name,
  ) async {
    final html = await _fetchText(url, name: name);
    return ItemPage.fromJson(await _call('parseList', [html, context]));
  }

  int _page(String cursor) {
    final page = int.tryParse(cursor);
    return page == null || page < 1 ? 1 : page;
  }

  @override
  Future<ItemPage> search(
    String query, {
    String cursor = '',
    int limit = 20,
    int tabType = 0,
  }) async {
    final context = <String, Object?>{
      'q': query,
      'cursor': cursor,
      'page': _page(cursor),
      'limit': limit,
    };
    final url =
        await _url('search', {'q': query, 'page': _page(cursor), 'limit': limit});
    return _list(url, context, 'search');
  }

  @override
  Future<ItemPage> feed({
    String channel = '',
    String cursor = '',
    int limit = 20,
  }) async {
    final context = <String, Object?>{
      'channel': channel,
      'cursor': cursor,
      'page': _page(cursor),
      'limit': limit,
      'paged': channel.isNotEmpty && channel != 'home',
    };
    final url = await _url('feed', context);
    return _list(url, context, 'feed');
  }

  @override
  Future<ItemPage> rank({
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  }) async {
    final context = <String, Object?>{
      'type': type.isNotEmpty ? type : (filter.isNotEmpty ? filter : 'movie'),
      'time': time.isNotEmpty ? time : (sub.isNotEmpty ? sub : 'total'),
      'cursor': cursor,
      'page': _page(cursor),
      'limit': limit,
    };
    final html = await _fetchText(await _url('rank', context), name: 'rank');
    return ItemPage.fromJson(await _call('parseRank', [html, context]));
  }

  @override
  Future<RankMeta> rankMeta({String type = '', String sub = ''}) async {
    final value = await _json('__FP_SOURCE.rankMeta()');
    if (value is Map)
      return RankMeta.fromJson(Map<String, dynamic>.from(value));
    return const RankMeta();
  }

  @override
  Future<ItemPage> newItems({
    String gender = '2',
    String cursor = '',
    int limit = 20,
  }) async {
    final context = <String, Object?>{
      'gender': gender,
      'cursor': cursor,
      'page': _page(cursor),
      'limit': limit,
      'paged': false,
    };
    return _list(await _url('new', context), context, 'new');
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
  }) async {
    final context = <String, Object?>{
      'type': tag,
      'genre': genre,
      'area': theme,
      'role': role,
      'year': epoch.isNotEmpty ? epoch : onlineTime,
      'sort': sort,
      'gender': gender,
      'cursor': cursor,
      'page': _page(cursor),
      'limit': limit,
    };
    return _list(await _url('category', context), context, 'category');
  }

  @override
  Future<List<Item>> hero() async {
    if (!_hasHero) return const <Item>[];
    final context = <String, Object?>{};
    final html = await _fetchText(await _url('hero', context), name: 'hero');
    final parsed = await _callOrNull('parseHero', [html, context]);
    if (parsed == null) return const <Item>[];
    return listOr(parsed['items'])
        .map((e) => Item.fromJson(mapOr(e)))
        .toList(growable: false);
  }

  @override
  Future<List<FilterGroup>> categoryMeta({String tag = ''}) async {
    final cached = _filterCache[tag];
    if (cached != null) return cached;
    final context = <String, Object?>{'type': tag};
    final html =
        await _fetchText(await _url('categoryMeta', context), name: 'categoryMeta');
    final parsed = await _call('parseCategoryMeta', [html, context]);
    final groups = listOr(parsed['groups'])
        .map((item) => FilterGroup.fromJson(mapOr(item)))
        .toList(growable: false);
    _filterCache[tag] = groups;
    return groups;
  }

  @override
  Future<List<HomeTab>> tabs() async => ui.homeTabs;

  @override
  Future<void> prefetchFeed({String channel = ''}) async {}

  Future<Map<String, dynamic>> _detail(String itemId) async {
    final cached = _detailCache[itemId];
    if (cached != null) return cached;
    final context = <String, Object?>{'id': itemId};
    final html = await _fetchText(await _url('detail', context), name: 'detail');
    final parsed = await _call('parseDetail', [html, context]);
    _detailCache[itemId] = parsed;
    if (_detailCache.length > 12) {
      _detailCache.remove(_detailCache.keys.first);
    }
    return parsed;
  }

  @override
  Future<Item> detail(String itemId) async {
    final parsed = await _detail(itemId);
    return Item.fromJson(mapOr(parsed['item']));
  }

  Map<String, dynamic>? _primaryLine(List<dynamic> lines) {
    Map<String, dynamic>? best;
    var bestCount = -1;
    for (final raw in lines) {
      final line = mapOr(raw);
      final count = listOr(line['episodes']).length;
      if (count > bestCount) {
        best = line;
        bestCount = count;
      }
    }
    return best;
  }

  @override
  Future<EpisodePage> episodes(String itemId, {String cursor = ''}) async {
    final parsed = await _detail(itemId);
    final line = _primaryLine(listOr(parsed['lines']));
    if (line == null) {
      throw const SpException(SpErrorCode.notFound, '没有可用剧集');
    }
    final sid = str(line['sid']);
    var position = 0;
    final episodes = listOr(line['episodes']).map((raw) {
      final episode = mapOr(raw);
      final nid = str(episode['nid']);
      final id = '$itemId-$sid-$nid';
      position++;
      final index = intOr(episode['index']);
      return {
        'episode_id': id,
        'id': id,
        // Display order, not the upstream episode id.
        'index': index > 0 ? index : position,
        'title': str(episode['title']),
        'extra': {
          'sid': sid,
          'nid': nid,
          'line_name': str(line['name']),
        },
      };
    }).toList(growable: false);
    return EpisodePage.fromJson({'episodes': episodes, 'next': ''});
  }

  @override
  Future<MediaPlan> play(PlayRequest request) async {
    final parsed = await _detail(request.itemId);
    final lines = listOr(parsed['lines']).map(mapOr).toList(growable: false);
    if (lines.isEmpty) {
      throw const SpException(SpErrorCode.notFound, '没有可用播放线路');
    }

    var sid = '';
    var nid = '';
    final match = RegExp(r'^(\d+)-(\d+)-(\d+)$').firstMatch(request.episodeId);
    if (match != null) {
      sid = match.group(2)!;
      nid = match.group(3)!;
    }

    Map<String, dynamic>? selected;
    for (final line in lines) {
      if (request.quality.isNotEmpty &&
          request.quality != 'auto' &&
          str(line['name']) == request.quality) {
        selected = line;
        break;
      }
      if (sid.isNotEmpty && str(line['sid']) == sid) {
        selected = line;
      }
    }
    selected ??= _primaryLine(lines);
    if (selected == null) {
      throw const SpException(SpErrorCode.notFound, '没有可用播放线路');
    }
    sid = str(selected['sid']);
    final episodes =
        listOr(selected['episodes']).map(mapOr).toList(growable: false);
    if (nid.isEmpty && episodes.isNotEmpty) {
      nid = str(episodes.first['nid']);
    }
    if (nid.isEmpty) {
      throw const SpException(SpErrorCode.notFound, '没有可用剧集');
    }

    final candidates = <Map<String, dynamic>>[selected];
    for (final line in lines) {
      if (line == selected) continue;
      final hasEpisode = listOr(line['episodes'])
          .map(mapOr)
          .any((episode) => str(episode['nid']) == nid);
      if (hasEpisode) candidates.add(line);
    }

    // A source may hand out a CDN line that answers 403 for this address and
    // a working one on the next request; ask again instead of leaving the
    // player black.
    for (var attempt = 0; attempt < 3; attempt++) {
      for (final line in candidates.take(4)) {
        final lineSid = str(line['sid']);
        final context = <String, Object?>{
          'item_id': request.itemId,
          'sid': lineSid,
          'nid': nid,
          'line_name': str(line['name']),
          'quality': request.quality,
        };
        try {
          final html = await _fetchText(await _url('play', context), name: 'play');
          final play = await _callOrNull('parsePlay', [html, context]);
          if (play == null) continue;

          // A package may expose several resolutions for one episode. Fall back
          // to the single-url shape used by older packages.
          final rawStreams = listOr(play['streams']);
          final variants = <Map<String, dynamic>>[
            if (rawStreams.isNotEmpty)
              for (final raw in rawStreams) mapOr(raw)
            else
              {'url': str(play['url']), 'name': str(play['name'])},
          ];

          final streams = <Stream>[];
          for (var i = 0; i < variants.length; i++) {
            final variant = variants[i];
            final upstreamUrl = str(variant['url']);
            if (upstreamUrl.isEmpty) continue;
            final String playUrl;
            if (directMedia) {
              playUrl = upstreamUrl;
            } else {
              if (!await _validPlaylist(upstreamUrl)) continue;
              playUrl = await LocalHlsProxy.instance.register(
                upstreamUrl,
                _mediaHeaders,
              );
            }
            final name = str(variant['name']);
            streams.add(
              Stream(
                id: '$lineSid-$i',
                quality: name.isEmpty ? str(line['name']) : name,
                height: intOr(variant['height']),
                container: 'hls',
                mimeType: 'application/vnd.apple.mpegurl',
                url: playUrl,
              ),
            );
          }
          if (streams.isEmpty) continue;
          if (directMedia &&
              streams.first.url.toLowerCase().contains('.m3u8') &&
              !await _validPlaylist(streams.first.url)) {
            continue;
          }

          var nextId = '';
          for (var index = 0; index < episodes.length; index++) {
            if (str(episodes[index]['nid']) != nid) continue;
            if (index + 1 < episodes.length) {
              nextId =
                  '${request.itemId}-$lineSid-${str(episodes[index + 1]['nid'])}';
            }
            break;
          }
          return MediaPlan(
            itemId: request.itemId,
            episodeId: '${request.itemId}-$lineSid-$nid',
            nextEpisodeId: nextId,
            streams: streams,
          );
        } on Object {
          // Try the next line.
        }
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw const SpException(SpErrorCode.upstreamFailed, '没有可用的播放线路');
  }

  Future<bool> _validPlaylist(String url) async {
    try {
      final text = await _fetchText(url, headersOverride: _mediaHeaders);
      return text.trimLeft().startsWith('#EXTM3U');
    } on Object {
      return false;
    }
  }

  @override
  Future<Map<String, ItemStats>> stats(
    List<String> itemIds, {
    String vid = '',
  }) async =>
      const {};

  @override
  Future<CalendarResult> calendar(
          {String date = '', String cursor = ''}) async =>
      const CalendarResult();

  @override
  @override
  Future<SuggestResult> suggest(String query, {int limit = 10}) async {
    if (!_hasSuggest || query.trim().isEmpty) return const SuggestResult();
    final context = <String, Object?>{'q': query, 'limit': limit};
    final html = await _fetchText(await _url('suggest', context), name: 'suggest');
    final parsed = await _callOrNull('parseSuggest', [html, context]);
    if (parsed == null) return const SuggestResult();
    return SuggestResult.fromJson(parsed);
  }

  @override
  Future<ItemPage> favorites({String cursor = '', int limit = 20}) async =>
      const ItemPage();

  @override
  Future<ItemPage> history({String cursor = '', int limit = 20}) async =>
      const ItemPage();

  @override
  Future<ItemPage> follows({String cursor = '', int limit = 20}) async =>
      const ItemPage();

  @override
  Future<ItemPage> likes({String cursor = '', int limit = 20}) async =>
      const ItemPage();

  @override
  Future<ItemPage> reservations({
    String cursor = '',
    int limit = 20,
    bool? online,
  }) async =>
      const ItemPage();

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
  Future<DanmakuPage> danmaku({
    required String itemId,
    required String episodeId,
    int durationSec = 0,
    int offsetSec = 0,
  }) async =>
      const DanmakuPage();

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
  Future<List<Map<String, dynamic>>> emoticons() async => const [];

  @override
  Future<void> setLike(String itemId, bool liked,
      {String episodeId = ''}) async {}

  @override
  Future<void> setFavorite(String itemId, bool favorite) async {}

  @override
  Future<void> setReservation(String itemId, bool reserve) async {}

  @override
  Future<void> setFollow(String itemId, bool followed) async {}

  @override
  Future<void> deleteReservations(List<String> itemIds,
      {bool online = false}) async {}

  @override
  Future<AccountUser> account() async => const AccountUser();

  @override
  Future<void> logout() async {}

  @override
  Future<String> shareLink({String itemId = '', String episodeId = ''}) async =>
      '';

  @override
  Future<LoginQr> loginQrCode() => Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持账号登录'),
      );

  @override
  Future<LoginStatus> loginQrStatus(String token) => Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持账号登录'),
      );

  @override
  Future<Map<String, dynamic>> sendSmsCode(String mobile) => Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持账号登录'),
      );

  @override
  Future<AccountUser> smsLogin({
    required String mobile,
    required String code,
  }) =>
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持账号登录'),
      );

  @override
  Future<Map<String, dynamic>> loginWith(
    String method,
    Map<String, String> fields,
  ) =>
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持账号登录'),
      );

  @override
  Future<String> sendDanmaku({
    required String itemId,
    required String episodeId,
    required String text,
    int offsetSec = 0,
  }) =>
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持弹幕'),
      );

  @override
  Future<String> addComment({
    required String itemId,
    String episodeId = '',
    String kind = 'comment',
    required String text,
    int offsetSec = 0,
  }) =>
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持评论'),
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
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持评论'),
      );

  @override
  Future<void> deleteComment(String commentId, {String kind = 'comment'}) =>
      Future.error(
        const SpException(SpErrorCode.unsupported, '本地源不支持评论'),
      );

  @override
  Future<void> likeComment(
    String commentId, {
    String kind = 'comment',
    bool liked = true,
    String itemId = '',
    String episodeId = '',
  }) async {}

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
  Future<List<Map<String, dynamic>>> endpoints() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw SpException(
      SpErrorCode.unsupported,
      '本地源暂不支持 ${invocation.memberName}',
    );
  }

  @override
  void close() {
    _http.close(force: true);
    _worker.close();
  }
}
