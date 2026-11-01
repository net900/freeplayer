/// SourceProtocol v1 DTOs. Field names mirror `source-protocol-v1.md`.
/// This file is hand-written for the skeleton; the OpenAPI generation step
/// will replace it once the backend schema is frozen (PRD §6.1).
library;

String str(Object? v) => v is String ? v : '';

int intOr(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double doubleOr(Object? v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

bool boolOr(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return fallback;
}

Map<String, dynamic> mapOr(Object? v) {
  if (v is Map) {
    return v.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

List<dynamic> listOr(Object? v) => v is List ? v : const [];

List<String> stringList(Object? v) =>
    listOr(v).map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();

class SourceManifest {
  const SourceManifest({
    required this.id,
    required this.name,
    this.version = '',
    this.protocol = '',
    this.description = '',
    this.icon = '',
    this.brand,
    this.capabilities = const [],
    this.auth,
    this.decryptors = const [],
    this.endpoints = const {},
    this.extra = const {},
  });

  final String id;
  final String name;
  final String version;
  final String protocol;
  final String description;
  final String icon;
  final SourceBrand? brand;
  final List<String> capabilities;
  final SourceAuthInfo? auth;

  /// Decryption modules: built-in ids and/or downloadable, hash-pinned DLLs.
  final List<DecryptorSpec> decryptors;

  /// Logical action -> path template. Any path is allowed; missing keys use
  /// the shell's default. Placeholders: {source_id}, {item_id}, {comment_id},
  /// {album_id}. A template may also be an absolute URL.
  final Map<String, String> endpoints;

  final Map<String, dynamic> extra;

  bool supports(String capability) => capabilities.contains(capability);

  factory SourceManifest.fromJson(Map<String, dynamic> json) {
    return SourceManifest(
      id: str(json['id']),
      name: str(json['name']),
      version: str(json['version']),
      protocol: str(json['protocol']),
      description: str(json['description']),
      icon: str(json['icon']),
      brand: json['brand'] == null
          ? null
          : SourceBrand.fromJson(mapOr(json['brand'])),
      capabilities: stringList(json['capabilities']),
      auth: json['auth'] == null
          ? null
          : SourceAuthInfo.fromJson(mapOr(json['auth'])),
      decryptors: listOr(json['decryptors'])
          .map((e) => DecryptorSpec.fromJson(mapOr(e)))
          .toList(growable: false),
      endpoints: {
        for (final entry in mapOr(json['endpoints']).entries)
          entry.key.toString(): entry.value?.toString() ?? '',
      }..removeWhere((key, value) => value.isEmpty),
      extra: mapOr(json['extra']),
    );
  }
}

/// A decryption module declared by a source. Built-in modules have an id but
/// no URL; downloadable modules pin a URL and SHA-256.
class DecryptorSpec {
  const DecryptorSpec({
    required this.id,
    this.version = '',
    this.os = '',
    this.arch = '',
    this.url = '',
    this.sha256 = '',
    this.size = 0,
    this.file = '',
    this.algorithms = const [],
    this.abi = 0,
  });

  final String id;
  final String version;
  final String os;
  final String arch;
  final String url;
  final String sha256;
  final int size;

  /// Installed file name (e.g. cenc_decrypt.dll); derived from the URL when
  /// empty.
  final String file;

  final List<String> algorithms;
  final int abi;

  bool get downloadable => url.isNotEmpty && sha256.isNotEmpty;

  factory DecryptorSpec.fromJson(Map<String, dynamic> json) {
    return DecryptorSpec(
      id: str(json['id']),
      version: str(json['version']),
      os: str(json['os']),
      arch: str(json['arch']),
      url: str(json['url']),
      sha256: str(json['sha256']).toLowerCase(),
      size: intOr(json['size']),
      file: str(json['file']),
      algorithms: stringList(json['algorithms']),
      abi: intOr(json['abi']),
    );
  }
}

class SourceBrand {
  const SourceBrand({this.theme});

  final SourceTheme? theme;

  factory SourceBrand.fromJson(Map<String, dynamic> json) {
    return SourceBrand(
      theme: json['theme'] == null
          ? null
          : SourceTheme.fromJson(mapOr(json['theme'])),
    );
  }
}

class SourceTheme {
  const SourceTheme({this.seed = '', this.mode = 'auto'});

  final String seed;
  final String mode;

  factory SourceTheme.fromJson(Map<String, dynamic> json) {
    return SourceTheme(
      seed: str(json['seed']),
      mode: str(json['mode']).isEmpty ? 'auto' : str(json['mode']),
    );
  }
}

class SourceAuthInfo {
  const SourceAuthInfo({
    this.required = false,
    this.methods = const [],
    this.login,
    this.credentialHeader = '',
    this.credentialPrefix = '',
  });

  final bool required;
  final List<String> methods;

  /// Source-defined login UI. When present the shell renders these fields
  /// instead of assuming a QR/SMS flow.
  final SourceLoginFlow? login;

  /// How the shell attaches a returned token. Defaults to
  /// `Authorization: Bearer <token>` when omitted.
  final String credentialHeader;
  final String credentialPrefix;

  factory SourceAuthInfo.fromJson(Map<String, dynamic> json) {
    return SourceAuthInfo(
      required: boolOr(json['required']),
      methods: stringList(json['methods']),
      login: json['login'] == null
          ? null
          : SourceLoginFlow.fromJson(mapOr(json['login'])),
      credentialHeader: str(json['credential_header']),
      credentialPrefix: str(json['credential_prefix']),
    );
  }
}

class SourceLoginFlow {
  const SourceLoginFlow({
    this.title = '',
    this.description = '',
    this.method = '',
    this.submitLabel = '',
    this.fields = const [],
    this.successFields = const [],
  });

  final String title;
  final String description;
  final String method;
  final String submitLabel;
  final List<SourceLoginField> fields;
  final List<String> successFields;

  bool get isCustom => fields.isNotEmpty;

  factory SourceLoginFlow.fromJson(Map<String, dynamic> json) {
    return SourceLoginFlow(
      title: str(json['title']),
      description: str(json['description']),
      method: str(json['method']),
      submitLabel: str(json['submit_label']),
      fields: listOr(json['fields'])
          .map((e) => SourceLoginField.fromJson(mapOr(e)))
          .toList(growable: false),
      successFields: stringList(json['success_fields']),
    );
  }
}

class SourceLoginField {
  const SourceLoginField({
    required this.key,
    this.label = '',
    this.type = 'text',
    this.required = false,
    this.placeholder = '',
  });

  final String key;
  final String label;
  final String type;
  final bool required;
  final String placeholder;

  factory SourceLoginField.fromJson(Map<String, dynamic> json) {
    return SourceLoginField(
      key: str(json['key']),
      label: str(json['label']),
      type: str(json['type']).isEmpty ? 'text' : str(json['type']),
      required: boolOr(json['required']),
      placeholder: str(json['placeholder']),
    );
  }
}

class Item {
  const Item({
    required this.id,
    required this.title,
    this.cover = '',
    this.description = '',
    this.type = '',
    this.updatedAt = '',
    this.episodeCount = 0,
    this.badges = const [],
    this.tags = const [],
    this.extra = const {},
  });

  final String id;
  final String title;
  final String cover;
  final String description;
  final String type;
  final String updatedAt;
  final int episodeCount;
  final List<String> badges;

  /// Genre labels supplied by the source; shown in rank rows and detail.
  final List<String> tags;
  final Map<String, dynamic> extra;

  factory Item.fromJson(Map<String, dynamic> json) {
    final extra = mapOr(json['extra']);
    return Item(
      id: str(json['id']).isEmpty ? str(json['item_id']) : str(json['id']),
      title: str(json['title']),
      cover: str(json['cover']),
      description: str(json['description']),
      type: str(json['type']),
      updatedAt: str(json['updated_at']),
      episodeCount: intOr(json['episode_count']) > 0
          ? intOr(json['episode_count'])
          : intOr(extra['episode_cnt']),
      badges: stringList(json['badges']),
      tags: stringList(json['tags']),
      extra: extra,
    );
  }
}

class ItemPage {
  const ItemPage({this.items = const [], this.next = '', this.total = 0});

  final List<Item> items;
  final String next;
  final int total;

  bool get hasMore => next.isNotEmpty;

  factory ItemPage.fromJson(Map<String, dynamic> json) {
    return ItemPage(
      items: listOr(json['items'])
          .map((e) => Item.fromJson(mapOr(e)))
          .toList(growable: false),
      next: str(json['next']),
      total: intOr(json['total']),
    );
  }
}

class Episode {
  const Episode({
    required this.id,
    this.index = 0,
    this.title = '',
    this.durationSec = 0,
    this.extra = const {},
  });

  final String id;
  final int index;
  final String title;
  final int durationSec;
  final Map<String, dynamic> extra;

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      id: str(json['id']),
      index: intOr(json['index']),
      title: str(json['title']),
      durationSec: intOr(json['duration_sec']),
      extra: mapOr(json['extra']),
    );
  }
}

class EpisodePage {
  const EpisodePage({this.episodes = const [], this.next = ''});

  final List<Episode> episodes;
  final String next;

  bool get hasMore => next.isNotEmpty;

  factory EpisodePage.fromJson(Map<String, dynamic> json) {
    return EpisodePage(
      episodes: listOr(json['episodes'])
          .map((e) => Episode.fromJson(mapOr(e)))
          .toList(growable: false),
      next: str(json['next']),
    );
  }
}

class PlayRequest {
  const PlayRequest({
    required this.itemId,
    required this.episodeId,
    this.quality = 'auto',
    this.maxHeight = 0,
    this.prewarm = false,
  });

  final String itemId;
  final String episodeId;
  final String quality;
  final int maxHeight;
  final bool prewarm;

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'episode_id': episodeId,
        'quality': quality,
        if (maxHeight > 0) 'prefer': {'max_height': maxHeight},
        if (prewarm) 'prewarm': true,
      };
}

class MediaPlan {
  const MediaPlan({
    this.itemId = '',
    this.episodeId = '',
    this.streams = const [],
    this.decryption = const DecryptionSpec(),
    this.expiresAt = '',
    this.nextEpisodeId = '',
    this.downgraded = false,
    this.extra = const {},
  });

  final String itemId;
  final String episodeId;
  final List<Stream> streams;
  final DecryptionSpec decryption;
  final String expiresAt;
  final String nextEpisodeId;
  final bool downgraded;
  final Map<String, dynamic> extra;

  Stream? get bestStream => streams.isEmpty ? null : streams.first;

  ThumbStrip? get thumbs {
    final raw = extra['thumbs'];
    if (raw is! Map) return null;
    final strip = ThumbStrip.fromJson(Map<String, dynamic>.from(raw));
    return strip.valid ? strip : null;
  }

  /// The preview sprite address on its own. Sources only send this; the shell
  /// downloads, decodes and slices the sheet itself.
  String? get spriteUrl {
    final raw = extra['thumbs'];
    if (raw is! Map) return null;
    final url = str(raw['url']);
    return url.isEmpty ? null : url;
  }

  factory MediaPlan.fromJson(Map<String, dynamic> json) {
    return MediaPlan(
      itemId: str(json['item_id']),
      episodeId: str(json['episode_id']),
      streams: listOr(json['streams'])
          .map((e) => Stream.fromJson(mapOr(e)))
          .toList(growable: false),
      decryption: json['decryption'] == null
          ? const DecryptionSpec()
          : DecryptionSpec.fromJson(mapOr(json['decryption'])),
      expiresAt: str(json['expires_at']),
      nextEpisodeId: str(json['next_episode_id']),
      downgraded: boolOr(json['downgraded']),
      extra: mapOr(json['extra']),
    );
  }
}

/// Progress-bar preview sprite: one image cut into cols×rows tiles.
class ThumbStrip {
  const ThumbStrip({
    this.url = '',
    this.cols = 0,
    this.rows = 0,
    this.count = 0,
    this.tileWidth = 0,
    this.tileHeight = 0,
    this.intervalSec = 1,
  });

  final String url;
  final int cols;
  final int rows;
  final int count;
  final int tileWidth;
  final int tileHeight;
  final double intervalSec;

  bool get valid =>
      url.isNotEmpty &&
      cols > 0 &&
      rows > 0 &&
      tileWidth > 0 &&
      tileHeight > 0;

  factory ThumbStrip.fromJson(Map<String, dynamic> json) => ThumbStrip(
        url: str(json['url']),
        cols: intOr(json['cols']),
        rows: intOr(json['rows']),
        count: intOr(json['count']),
        tileWidth: intOr(json['tile_width']),
        tileHeight: intOr(json['tile_height']),
        intervalSec: doubleOr(
          json['interval_sec'],
          doubleOr(json['interval'], 1),
        ),
      );
}

class Stream {
  const Stream({
    this.id = '',
    this.quality = '',
    this.height = 0,
    this.width = 0,
    this.bandwidth = 0,
    this.codec = '',
    this.container = '',
    this.url = '',
    this.mimeType = '',
    this.decryption,
    this.extra = const {},
  });

  final String id;
  final String quality;
  final int height;
  final int width;
  final int bandwidth;
  final String codec;
  final String container;
  final String url;
  final String mimeType;

  /// Per-stream protection. Falls back to the plan-level spec when absent.
  final DecryptionSpec? decryption;
  final Map<String, dynamic> extra;

  factory Stream.fromJson(Map<String, dynamic> json) {
    return Stream(
      id: str(json['id']),
      quality: str(json['quality']),
      height: intOr(json['height']),
      width: intOr(json['width']),
      bandwidth: intOr(json['bandwidth']),
      codec: str(json['codec']),
      container: str(json['container']),
      url: str(json['url']),
      mimeType: str(json['mime_type']),
      decryption: json['decryption'] == null
          ? null
          : DecryptionSpec.fromJson(mapOr(json['decryption'])),
      extra: mapOr(json['extra']),
    );
  }
}

class DecryptionSpec {
  const DecryptionSpec({
    this.required = false,
    this.algorithm = 'none',
    this.location = 'server',
    this.handler = '',
    this.keyHex = '',
    this.ivSize = 0,
    this.params = const {},
  });

  final bool required;
  final String algorithm;
  final String location;
  final String handler;

  /// Content key for client-side decryption, hex encoded.
  final String keyHex;
  final int ivSize;
  final Map<String, String> params;

  factory DecryptionSpec.fromJson(Map<String, dynamic> json) {
    final params = <String, String>{};
    mapOr(json['params']).forEach((key, value) {
      params[key] = value?.toString() ?? '';
    });
    return DecryptionSpec(
      required: boolOr(json['required']),
      algorithm: str(json['algorithm']).isEmpty ? 'none' : str(json['algorithm']),
      location: str(json['location']).isEmpty ? 'server' : str(json['location']),
      handler: str(json['handler']),
      keyHex: str(json['key_hex']),
      ivSize: intOr(json['iv_size']),
      params: params,
    );
  }
}

class UIManifest {
  const UIManifest({
    this.navigation = const [],
    this.homeTabs = const [],
    this.defaultPage = '',
    this.theme,
    this.labels = const {},
    this.newGenderTabs = true,
  });

  final List<NavGroup> navigation;

  /// Home in-page tabs shipped with the config, so the shell never needs a
  /// built-in default or a second request before drawing the first screen.
  final List<HomeTab> homeTabs;

  final String defaultPage;
  final SourceTheme? theme;

  /// Copy supplied by the source (e.g. the feed's full-play button). The
  /// shell never invents product text of its own.
  final Map<String, String> labels;

  /// Whether the new-items page shows its audience row (全部/男频/女频).
  /// Sources without audience data set `new_gender_tabs: false`.
  final bool newGenderTabs;

  factory UIManifest.fromJson(Map<String, dynamic> json) {
    return UIManifest(
      navigation: listOr(json['navigation'])
          .map((e) => NavGroup.fromJson(mapOr(e)))
          .toList(growable: false),
      homeTabs: listOr(json['home_tabs'])
          .map((e) => HomeTab.fromJson(mapOr(e)))
          .toList(growable: false),
      defaultPage: str(json['default_page']),
      theme: json['theme'] == null
          ? null
          : SourceTheme.fromJson(mapOr(json['theme'])),
      labels: {
        for (final entry in mapOr(json['labels']).entries)
          entry.key: entry.value?.toString() ?? '',
      },
      newGenderTabs: json['new_gender_tabs'] == null
          ? true
          : boolOr(json['new_gender_tabs']),
    );
  }
}

class NavGroup {
  const NavGroup({this.title = '', this.icon = '', this.items = const []});

  final String title;
  final String icon;
  final List<NavItem> items;

  factory NavGroup.fromJson(Map<String, dynamic> json) {
    return NavGroup(
      title: str(json['title']),
      icon: str(json['icon']),
      items: listOr(json['items'])
          .map((e) => NavItem.fromJson(mapOr(e)))
          .toList(growable: false),
    );
  }
}

class NavItem {
  const NavItem({
    this.title = '',
    this.icon = '',
    this.page = '',
    this.params = const {},
    this.actions = const [],
  });

  final String title;
  final String icon;
  final String page;
  final Map<String, String> params;
  final List<NavAction> actions;

  factory NavItem.fromJson(Map<String, dynamic> json) {
    final params = <String, String>{};
    mapOr(json['params']).forEach((key, value) {
      params[key] = value?.toString() ?? '';
    });
    return NavItem(
      title: str(json['title']),
      icon: str(json['icon']),
      page: str(json['page']),
      params: params,
      actions: listOr(json['actions'])
          .map((e) => NavAction.fromJson(mapOr(e)))
          .toList(growable: false),
    );
  }
}

class NavAction {
  const NavAction({
    this.id = '',
    this.title = '',
    this.icon = '',
    this.type = '',
    this.method = '',
  });

  final String id;
  final String title;
  final String icon;
  final String type;
  final String method;

  factory NavAction.fromJson(Map<String, dynamic> json) {
    return NavAction(
      id: str(json['id']),
      title: str(json['title']),
      icon: str(json['icon']),
      type: str(json['type']),
      method: str(json['method']),
    );
  }
}

/// One entry of the home page's in-page navigation, supplied by the source.
class HomeTab {
  const HomeTab({
    required this.key,
    required this.title,
    required this.channel,
    this.requiresAuth = false,
    this.categoryTag = '',
  });

  final String key;
  final String title;
  final String channel;

  /// The account must be signed in for this tab; supplied by the source.
  final bool requiresAuth;

  /// Category tag used to extend a short tab when its feed runs out.
  final String categoryTag;

  factory HomeTab.fromJson(Map<String, dynamic> json) => HomeTab(
        key: str(json['key']),
        title: str(json['title']),
        channel: str(json['channel']),
        requiresAuth: boolOr(json['requires_auth']),
        categoryTag: str(json['category_tag']),
      );
}

/// Counts and season metadata that a feed row does not carry.
class ItemStats {
  const ItemStats({
    this.episodeCount = 0,
    this.episodeIndex = 0,
    this.playCount = 0,
    this.likeCount = 0,
    this.commentCount = 0,
    this.followCount = 0,
    this.favoriteCount = 0,
    this.seasonIndex = 0,
    this.multiSeason = false,
    this.status = 0,
    this.durationSec = 0,
    this.categories = const [],
    this.liked = false,
  });

  final int episodeCount;
  final int episodeIndex;
  final int playCount;
  final int likeCount;
  final int commentCount;
  final int followCount;
  final int favoriteCount;
  final int seasonIndex;
  final bool multiSeason;
  final int status;
  final int durationSec;
  final List<String> categories;
  final bool liked;

  static ItemStats? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = mapOr(raw);
    if (json['error'] != null) return null;
    return ItemStats(
      episodeCount: intOr(json['episode_cnt']),
      episodeIndex: intOr(json['episode_index']),
      playCount: intOr(json['play_count']),
      likeCount: intOr(json['like_count']),
      commentCount: intOr(json['comment_count']),
      followCount: intOr(json['follow_count']),
      favoriteCount: intOr(json['favorite_count']),
      seasonIndex: intOr(json['season_index']),
      multiSeason: boolOr(json['multi_season']),
      status: intOr(json['status']),
      durationSec: intOr(json['duration_sec']),
      categories: stringList(json['categories']),
      liked: boolOr(json['liked']),
    );
  }
}

/// 上新日历: selectable dates plus the dramas scheduled for one day.
class CalendarResult {
  const CalendarResult({
    this.dates = const [],
    this.currentDate = '',
    this.defaultDate = '',
    this.targetDate = '',
    this.items = const [],
    this.next = '',
  });

  final List<String> dates;
  final String currentDate;
  final String defaultDate;
  final String targetDate;
  final List<Item> items;
  final String next;

  factory CalendarResult.fromJson(Map<String, dynamic> json) => CalendarResult(
        dates: stringList(json['dates']),
        currentDate: str(json['current_date']),
        defaultDate: str(json['default_date']),
        targetDate: str(json['target_date']),
        items: listOr(json['items'])
            .map((e) => Item.fromJson(mapOr(e)))
            .toList(growable: false),
        next: str(json['next']),
      );
}

class SuggestResult {
  const SuggestResult({this.words = const [], this.items = const []});

  final List<String> words;
  final List<Item> items;

  factory SuggestResult.fromJson(Map<String, dynamic> json) => SuggestResult(
        words: stringList(json['words']),
        items: listOr(json['items'])
            .map((e) => Item.fromJson(mapOr(e)))
            .toList(growable: false),
      );
}

class DanmakuLine {
  const DanmakuLine({
    this.id = '',
    this.time = 0,
    this.text = '',
    this.color = '#FFFFFF',
    this.mode = 'scroll',
    this.likeCount = 0,
    this.liked = false,
    this.userName = '',
  });

  final String id;
  final double time;
  final String text;
  final String color;
  final String mode;
  final int likeCount;
  final bool liked;
  final String userName;

  DanmakuLine copyWith({bool? liked, int? likeCount}) => DanmakuLine(
        id: id,
        time: time,
        text: text,
        color: color,
        mode: mode,
        likeCount: likeCount ?? this.likeCount,
        liked: liked ?? this.liked,
        userName: userName,
      );

  factory DanmakuLine.fromJson(Map<String, dynamic> json) => DanmakuLine(
        id: str(json['id']),
        time: doubleOr(json['t']),
        text: str(json['text']),
        color: str(json['color']).isEmpty ? '#FFFFFF' : str(json['color']),
        mode: str(json['mode']).isEmpty ? 'scroll' : str(json['mode']),
        likeCount: intOr(json['like_count']),
        liked: boolOr(json['liked']),
        userName: str(json['user_name']),
      );
}

class FilterOption {
  const FilterOption({required this.id, required this.label, this.parent = ''});

  final String id;
  final String label;

  /// For a dependent row, the id of the option it belongs to (e.g. the
  /// rank outer category).
  final String parent;

  factory FilterOption.fromJson(Map<String, dynamic> json) => FilterOption(
        id: str(json['id']),
        label: str(json['label']),
        parent: str(json['parent']),
      );
}

class FilterGroup {
  const FilterGroup({
    required this.key,
    required this.title,
    this.multi = false,
    this.dependsOn = '',
    this.options = const [],
  });

  final String key;
  final String title;
  final bool multi;

  /// Key of the group this row narrows; options are filtered by the selected
  /// parent option id.
  final String dependsOn;
  final List<FilterOption> options;

  factory FilterGroup.fromJson(Map<String, dynamic> json) => FilterGroup(
        key: str(json['key']),
        title: str(json['title']),
        multi: boolOr(json['multi']),
        dependsOn: str(json['depends_on']),
        options: listOr(json['options'])
            .map((e) => FilterOption.fromJson(mapOr(e)))
            .toList(growable: false),
      );
}

class RankMeta {
  const RankMeta({this.groups = const [], this.defaults = const {}});

  final List<FilterGroup> groups;
  final Map<String, String> defaults;

  factory RankMeta.fromJson(Map<String, dynamic> json) {
    final defaults = <String, String>{};
    mapOr(json['defaults']).forEach((key, value) {
      defaults[key] = value?.toString() ?? '';
    });
    return RankMeta(
      groups: listOr(json['groups'])
          .map((e) => FilterGroup.fromJson(mapOr(e)))
          .toList(growable: false),
      defaults: defaults,
    );
  }
}

class Comment {
  const Comment({
    required this.id,
    this.text = '',
    this.userName = '',
    this.avatar = '',
    this.createdAt = 0,
    this.likeCount = 0,
    this.replyCount = 0,
    this.liked = false,
    this.isMine = false,
  });

  final String id;
  final String text;
  final String userName;
  final String avatar;
  final int createdAt;
  final int likeCount;
  final int replyCount;
  final bool liked;
  final bool isMine;

  Comment copyWith({bool? liked, int? likeCount}) => Comment(
        id: id,
        text: text,
        userName: userName,
        avatar: avatar,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount,
        liked: liked ?? this.liked,
        isMine: isMine,
      );

  factory Comment.fromJson(Map<String, dynamic> json) => Comment(
        id: str(json['id']),
        text: str(json['text']),
        userName: str(json['user_name']),
        avatar: str(json['avatar']),
        createdAt: intOr(json['created_at']),
        likeCount: intOr(json['like_count']),
        replyCount: intOr(json['reply_count']),
        liked: boolOr(json['liked']),
        isMine: boolOr(json['is_mine']),
      );
}

class CommentPage {
  const CommentPage({
    this.items = const [],
    this.total = 0,
    this.next = '',
    this.hasMore = false,
    this.source = '',
  });

  final List<Comment> items;
  final int total;
  final String next;
  final bool hasMore;
  final String source;

  factory CommentPage.fromJson(Map<String, dynamic> json) => CommentPage(
        items: listOr(json['items'])
            .map((e) => Comment.fromJson(mapOr(e)))
            .toList(growable: false),
        total: intOr(json['total']),
        next: str(json['next']),
        hasMore: boolOr(json['has_more']),
        source: str(json['source']),
      );
}

class DanmakuPage {
  const DanmakuPage({
    this.items = const [],
    this.next = '',
    this.hasMore = false,
    this.source = '',
    this.notice = '',
  });

  final List<DanmakuLine> items;
  final String next;
  final bool hasMore;
  final String source;
  final String notice;

  factory DanmakuPage.fromJson(Map<String, dynamic> json) => DanmakuPage(
        items: listOr(json['items'])
            .map((e) => DanmakuLine.fromJson(mapOr(e)))
            .toList(growable: false),
        next: str(json['next']),
        hasMore: boolOr(json['has_more']),
        source: str(json['source']),
        notice: str(json['notice']),
      );
}

class LoginQr {
  const LoginQr({
    required this.token,
    required this.image,
    this.expireAt = 0,
    this.copywriting = '',
  });

  final String token;
  final String image;
  final int expireAt;
  final String copywriting;

  factory LoginQr.fromJson(Map<String, dynamic> json) => LoginQr(
        token: str(json['token']),
        image: str(json['image']),
        expireAt: intOr(json['expire_at']),
        copywriting: str(json['copywriting']),
      );
}

class AccountUser {
  const AccountUser({
    this.loggedIn = false,
    this.userId = '',
    this.userName = '',
    this.avatar = '',
  });

  final bool loggedIn;
  final String userId;
  final String userName;
  final String avatar;

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
        loggedIn: boolOr(json['logged_in']),
        userId: str(json['user_id']),
        userName: str(json['user_name']),
        avatar: str(json['avatar']),
      );
}

class LoginStatus {
  const LoginStatus({
    required this.status,
    this.description = '',
    this.loggedIn = false,
    this.user,
  });

  final String status;
  final String description;
  final bool loggedIn;
  final AccountUser? user;

  bool get confirmed => status == 'confirmed';

  factory LoginStatus.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    return LoginStatus(
      status: str(json['status']),
      description: str(json['description']),
      loggedIn: boolOr(json['logged_in']),
      user: rawUser is Map ? AccountUser.fromJson(mapOr(rawUser)) : null,
    );
  }
}

class ApiEnvelope {
  const ApiEnvelope({
    required this.code,
    required this.message,
    this.data,
    this.traceId = '',
  });

  final int code;
  final String message;
  final Object? data;
  final String traceId;

  bool get ok => code == 0;

  factory ApiEnvelope.fromJson(Map<String, dynamic> json) {
    return ApiEnvelope(
      code: intOr(json['code']),
      message: str(json['message']),
      data: json['data'],
      traceId: str(json['trace_id']),
    );
  }
}

/// Protocol error codes from PRD §9.4.
abstract final class SpErrorCode {
  static const int ok = 0;
  static const int badRequest = 40001;
  static const int unauthorized = 40100;
  static const int forbidden = 40300;
  static const int notFound = 40400;
  static const int decryptorMissing = 40410;
  static const int rateLimited = 42900;
  static const int upstreamFailed = 50010;
  static const int transcodeFailed = 50020;
  static const int unsupported = 50100;
}

class SpException implements Exception {
  const SpException(this.code, this.message, {this.traceId = ''});

  final int code;
  final String message;
  final String traceId;

  @override
  String toString() =>
      'SpException($code): $message${traceId.isEmpty ? '' : ' [$traceId]'}';
}
