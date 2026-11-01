import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../library/local_library.dart';
import '../renderer/page_registry.dart';
import '../sp/emoji.dart';
import '../sp/models.dart';
import '../sp/quality.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';
import 'comment_sheet.dart';
import 'common.dart';
import 'login_sheet.dart';
import 'loading.dart';
import '../downloads/download_sheet.dart';
import 'navigation.dart';
import 'page_title.dart';
import 'player_page.dart';
import 'poster_card.dart';
import 'route.dart';
import 'series_album.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.ctx});

  final PageContext ctx;

  @override
  Widget build(BuildContext context) {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) {
      return const StatePanel(
        icon: Icons.movie_outlined,
        title: AppStrings.emptyTitle,
        body: AppStrings.emptyBody,
      );
    }
    return AppAsyncView<Item>(
      load: () => api.detail(ctx.itemId),
      skeleton: const SkeletonList(),
      builder: (context, item) => DetailContent(item: item, api: api),
    );
  }
}

class DetailContent extends StatefulWidget {
  const DetailContent({
    super.key,
    required this.item,
    required this.api,
    this.poster = '',
  });

  final Item item;
  final SourceApi api;

  /// Vertical poster from the list/player. `video_detail.cover` is a landscape
  /// banner (640×360), so it must not be used in the 3:4 poster frame.
  final String poster;

  @override
  State<DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends State<DetailContent> {
  EpisodePage? _episodes;
  Object? _error;
  bool _loading = true;
  bool _started = false;
  bool _favorite = false;
  bool _favoriteLoaded = false;
  bool _playing = false;
  bool _liked = false;
  bool _reserved = false;
  int _likeCount = 0;
  int _commentCount = 0;
  int _remoteIndex = -1;
  String _remoteVid = '';
  int _remoteWatchedMs = 0;
  Item? _fresh;
  String _score = '';
  int _pendingInitial = 0;
  Map<String, int> _localPositions = const {};
  List<Item> _albumItems = const [];
  Set<String> _reservedAlbum = const {};
  List<Item> _related = const [];
  static const int _tabEpisodes = 0;
  static const int _tabSeries = 1;
  static const int _tabReviews = 2;
  static const int _tabRelated = 3;
  int _tab = _tabEpisodes;
  List<Comment> _comments = const [];
  bool _commentsLoading = false;
  bool _commentsLoaded = false;
  bool _commentsLoadingMore = false;
  String _commentNext = '';
  final ScrollController _commentsScroll = ScrollController();
  String? _commentsError;

  String get _seriesKey => '${widget.api.sourceId}:${widget.item.id}';

  @override
  void initState() {
    super.initState();
    final extra = widget.item.extra;
    _liked = extra['liked'] == true;
    _reserved = extra['followed'] == true;
    _likeCount = extra['like_count'] is num
        ? (extra['like_count'] as num).toInt()
        : 0;
    _commentCount = extra['comment_count'] is num
        ? (extra['comment_count'] as num).toInt()
        : 0;
    _score = (extra['score'] ?? '').toString().trim();
    _commentsScroll.addListener(_maybeLoadMoreComments);
  }

  void _initialDone() {
    if (!mounted) return;
    setState(() {
      if (_pendingInitial > 0) _pendingInitial--;
    });
  }

  /// The detail payload has no rating for every title; a suggestion lookup is
  /// cheap and runs after the page is already usable.
  Future<void> _loadScoreFallback(String title) async {
    if (title.isEmpty) return;
    try {
      final result = await widget.api.suggest(title, limit: 5);
      var next = '';
      for (final item in result.items) {
        final value = (item.extra['score'] ?? '').toString().trim();
        if (value.isEmpty) continue;
        if (item.id == widget.item.id || item.title == title) {
          next = value;
          break;
        }
        if (next.isEmpty) next = value;
      }
      if (!mounted || next.isEmpty) return;
      setState(() => _score = next);
    } on Object {
      // A missing rating is better than delaying the page.
    }
  }

  Future<void> _loadAlbum() async {
    try {
      final page = await widget.api.album(widget.item.id);
      if (!mounted) return;
      setState(() => _albumItems = page.items);
      unawaited(_loadAlbumReservations());
    } on Object {
      // 作品系列 is optional; the tab simply stays empty.
    }
  }

  Future<void> _loadAlbumReservations() async {
    final ids = <String>{};
    try {
      for (final online in const [false, true]) {
        final page = await widget.api.reservations(limit: 50, online: online);
        for (final item in page.items) {
          if (item.id.isNotEmpty) ids.add(item.id);
        }
      }
    } on Object {
      // Logged out: nothing is marked 已预约.
    }
    if (mounted) setState(() => _reservedAlbum = ids);
  }

  Future<bool> _reserveAlbumItem(Item item) async {
    final ok = await _runAuthAware(
      () => widget.api.setReservation(item.id, true),
    );
    if (ok && mounted) {
      setState(() => _reservedAlbum = {..._reservedAlbum, item.id});
    }
    return ok;
  }

  Future<void> _loadRelated() async {
    try {
      final page = await widget.api.related(widget.item.id);
      if (!mounted) return;
      setState(() => _related = page.items);
    } on Object {
      // Related works are optional.
    }
  }

  /// video_detail's followed/has_digg flags lag behind the account, so the
  /// gateway rebuilds them. Refresh them when the page opens.
  Future<void> _loadStats() async {
    try {
      final fresh = await widget.api.detail(widget.item.id);
      if (!mounted) return;
      final extra = fresh.extra;
      final freshScore = (extra['score'] ?? '').toString().trim();
      setState(() {
        _fresh = fresh;
        if (freshScore.isNotEmpty) _score = freshScore;
        if (extra.containsKey('liked')) _liked = extra['liked'] == true;
        if (extra.containsKey('followed')) {
          _reserved = extra['followed'] == true;
        }
        final likeCount = extra['like_count'];
        if (likeCount is num && likeCount > 0) {
          _likeCount = likeCount.toInt();
        }
        final commentCount = extra['comment_count'];
        if (commentCount is num && commentCount > 0) {
          _commentCount = commentCount.toInt();
        }
      });
      if (_score.isEmpty) {
        unawaited(_loadScoreFallback(fresh.title));
      }
    } on Object {
      // The list payload already carries a reasonable guess.
    }
  }

  @override
  void dispose() {
    _commentsScroll.removeListener(_maybeLoadMoreComments);
    _commentsScroll.dispose();
    super.dispose();
  }

  void _maybeLoadMoreComments() {
    if (!_commentsScroll.hasClients) return;
    if (_commentsScroll.position.extentAfter < 400) {
      unawaited(_loadComments(more: true));
    }
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
    if (index == _tabReviews) unawaited(_loadComments());
  }

  Future<void> _loadComments({bool more = false}) async {
    if (more) {
      if (_commentsLoadingMore || _commentNext.isEmpty) return;
      setState(() => _commentsLoadingMore = true);
    } else {
      if (_commentsLoaded || _commentsLoading) return;
      setState(() {
        _commentsLoading = true;
        _commentsError = null;
      });
    }
    try {
      final episodes = _episodes?.episodes ?? const <Episode>[];
      final page = await widget.api.comments(
        itemId: widget.item.id,
        episodeId: episodes.isEmpty ? '' : episodes.first.id,
        kind: 'review',
        cursor: more ? _commentNext : '',
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        final seen = _comments.map((comment) => comment.id).toSet();
        _comments = more
            ? [
                ..._comments,
                ...page.items.where((comment) => !seen.contains(comment.id)),
              ]
            : page.items;
        _commentNext = page.next;
        _commentsLoaded = true;
        _commentsLoading = false;
        _commentsLoadingMore = false;
        if (page.total > 0) _commentCount = page.total;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _commentsError = describeGatewayError(error);
        _commentsLoading = false;
        _commentsLoadingMore = false;
      });
    }
  }

  Future<bool> _requireLogin(Object error) async {
    if (error is SpException && error.code == SpErrorCode.unauthorized) {
      if (!mounted) return false;
      final api = widget.api;
      final ok = await showLoginSheet(context, api: api);
      return ok;
    }
    return false;
  }

  Future<bool> _runAuthAware(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object catch (error) {
      if (!mounted) return false;
      final loggedIn = await _requireLogin(error);
      if (!loggedIn || !mounted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(describeGatewayError(error))),
          );
        }
        return false;
      }
      try {
        await action();
        return true;
      } on Object catch (retryError) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(retryError.toString())),
        );
        return false;
      }
    }
  }

  /// The drama's like is the first episode's like: that is the number the
  /// detail page shows, and it stays independent from the episode you are
  /// watching (that one is liked from the player).
  String _likeEpisodeId() {
    final first = (_fresh ?? widget.item).extra['first_vid'];
    if (first is String && first.isNotEmpty) return first;
    final episodes = _episodes?.episodes ?? const <Episode>[];
    return episodes.isEmpty ? '' : episodes.first.id;
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    final previousCount = _likeCount;
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
    });
    final ok = await _runAuthAware(() async {
      await widget.api.setLike(
        widget.item.id,
        next,
        episodeId: _likeEpisodeId(),
      );
    });
    if (!ok && mounted) {
      setState(() {
        _liked = !next;
        _likeCount = previousCount;
      });
    }
  }

  /// Whether the series has started airing. A failed episode request must not
  /// turn a released drama into an unreleased one.
  bool get _released {
    final extra = (_fresh ?? widget.item).extra;
    if (extra['is_online'] is bool) return extra['is_online'] == true;
    final status = extra['status'];
    if (status is num && status > 0) return true;
    return (_episodes?.episodes ?? const <Episode>[]).isNotEmpty;
  }

  Future<void> _toggleReservation() async {
    final released = _released;
    final next = !_reserved;
    setState(() => _reserved = next);
    final ok = await _runAuthAware(() async {
      // Released series are followed (追更); only unreleased ones can be
      // reserved. The upstream rejects reserving a live series.
      if (released) {
        await widget.api.setFollow(widget.item.id, next);
      } else {
        await widget.api.setReservation(widget.item.id, next);
      }
    });
    if (!ok && mounted) setState(() => _reserved = !next);
  }

  Future<void> _share() async {
    await _runAuthAware(() async {
      final url = await widget.api.shareLink(itemId: widget.item.id);
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制分享链接：$url')),
      );
    });
  }

  Future<void> _openComments() async {
    final api = widget.api;
    // The comment groups are keyed by the episode vid: a series id accepts
    // writes but reads back empty, so 剧评 also uses the first episode.
    final episodes = _episodes?.episodes ?? const <Episode>[];
    final changed = await showCommentSheet(
      context,
      api: api,
      itemId: widget.item.id,
      episodeId: episodes.isEmpty ? '' : episodes.first.id,
      kind: 'review',
      title: '剧评',
      emptyText: '这部剧还没有剧评',
    );
    if (changed && mounted) {
      setState(() => _commentCount += 1);
    }
  }

  /// The first screen's requests start here, not in [initState]: they read
  /// AppScope (library, controller) before their first await, and Flutter
  /// forbids reading an inherited widget until initState has finished. The
  /// page used to fail with "dependOnInheritedWidgetOfExactType was called
  /// before initState completed", which only a manual 重试 could clear.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_favoriteLoaded) {
      _favoriteLoaded = true;
      _loadFavorite();
    }
    if (_started) return;
    _started = true;
    // Every initial request runs concurrently; the bar disappears when the
    // slowest one settles. Only the data visible on the first screen counts
    // toward the hint; the series and related sections keep loading in the
    // background.
    _pendingInitial = 3;
    _loadEpisodes().whenComplete(_initialDone);
    unawaited(_loadAccountProgress().whenComplete(_initialDone));
    unawaited(_loadStats().whenComplete(_initialDone));
    unawaited(_loadRelated());
    unawaited(_loadAlbum());
  }

  Future<void> _loadEpisodes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Read the scope before awaiting: the element can be gone by the time
      // the request returns.
      final library = AppScope.of(context).library;
      final page = await widget.api.episodes(widget.item.id);
      final positions = await library.episodePositions(_seriesKey);
      if (!mounted) return;
      setState(() {
        _episodes = page;
        _localPositions = positions;
        _loading = false;
      });
      // Comments opened before this list existed had no episode id and came
      // back empty; fetch them again now that one is known.
      if (_commentsLoaded && _comments.isEmpty) {
        _commentsLoaded = false;
        unawaited(_loadComments());
      }
      unawaited(_loadAccountProgress());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Reads the account's last position so another device's progress shows up
  /// here too. Best-effort: logged-out or offline keeps the local record.
  Future<void> _loadAccountProgress() async {
    try {
      final payload = await widget.api.progress(widget.item.id);
      if (!mounted || payload['logged_in'] == false) return;
      for (final row in _progressRows(payload)) {
        final id =
            '${row['book_id'] ?? row['book_id_str'] ?? row['series_id'] ?? ''}';
        if (id != widget.item.id) continue;
        final index = row['vid_index'];
        if (!mounted) return;
        setState(() {
          _remoteIndex = index is num ? index.toInt() : -1;
          _remoteVid = '${row['vid'] ?? ''}';
          final at = row['last_watch_time'];
          _remoteWatchedMs = at is num ? at.toInt() : 0;
        });
        return;
      }
      await _loadHistoryFallback();
    } on Object {
      // The local library still drives resume when the account is unavailable.
    }
  }

  /// read_progress/get only contains real playback rows; our own uploads may
  /// land in read_history/list instead (§3.4.5).
  Future<void> _loadHistoryFallback() async {
    try {
      final page = await widget.api.history(limit: 50);
      for (final item in page.items) {
        if (item.id != widget.item.id) continue;
        if (!mounted) return;
        final index = item.extra['vid_index'];
        setState(() {
          if (index is num) _remoteIndex = index.toInt();
          final vid = item.extra['vid'];
          if (vid is String) _remoteVid = vid;
        });
        return;
      }
    } on Object {
      // Local positions still drive resume.
    }
  }

  List<Map<String, dynamic>> _progressRows(Map<String, dynamic> payload) {
    final out = <Map<String, dynamic>>[];
    void take(Object? value) {
      if (value is! List) return;
      for (final row in value) {
        if (row is Map) out.add(Map<String, dynamic>.from(row));
      }
    }

    final data = payload['data'];
    if (data is Map) {
      take(data['video_data']);
      take(data['data']);
    }
    take(payload['video_data']);
    return out;
  }

  Episode? _remoteEpisode(List<Episode> episodes) {
    for (final episode in episodes) {
      if (_remoteVid.isNotEmpty && episode.id == _remoteVid) return episode;
    }
    for (final episode in episodes) {
      if (_remoteIndex >= 0 && episode.index == _remoteIndex) return episode;
    }
    return null;
  }

  Future<void> _loadFavorite() async {
    final library = AppScope.of(context).library;
    final favorite = await library.isFavorite(_seriesKey);
    if (!mounted) return;
    setState(() => _favorite = favorite);
  }

  Future<void> _toggleFavorite() async {
    final library = AppScope.of(context).library;
    final item = widget.item;
    final next = !_favorite;
    try {
      await widget.api.setFavorite(item.id, next);
    } on Object catch (error) {
      // Local favorites still work offline; the upstream shelf is best-effort.
      if (error is SpException && error.code == SpErrorCode.unauthorized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已保存到本地收藏；登录后可同步到账号')),
          );
        }
      }
    }
    await library.toggleFavorite(
      LibraryRecord(
        seriesKey: _seriesKey,
        title: item.title,
        cover: item.cover,
        sourceId: widget.api.sourceId,
        itemId: item.id,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    if (!mounted) return;
    setState(() => _favorite = !_favorite);
  }

  Future<void> _playResume() async {
    final episodes = _episodes?.episodes ?? const <Episode>[];
    if (episodes.isEmpty) return;
    var target = episodes.first;
    Episode? local;
    DateTime? localAt;
    final history = await AppScope.of(context).library.history();
    for (final record in history) {
      if (record.seriesKey != _seriesKey || record.episodeId.isEmpty) continue;
      for (final episode in episodes) {
        if (episode.id == record.episodeId) {
          local = episode;
          break;
        }
      }
      localAt = DateTime.tryParse(record.updatedAt);
      break;
    }
    final remote = _remoteEpisode(episodes);
    // Whichever side watched more recently wins: local catches this device,
    // the account covers every other device.
    final remoteWins = remote != null &&
        (local == null ||
            _remoteWatchedMs > (localAt?.millisecondsSinceEpoch ?? 0));
    if (remoteWins) {
      target = remote;
    } else if (local != null) {
      target = local;
    }
    await _play(target);
  }

  bool _watched(Episode episode) {
    if ((_localPositions[episode.id] ?? 0) > 5) return true;
    return _remoteIndex >= 0 && episode.index <= _remoteIndex;
  }

  String _playLabel() {
    final episodes = _episodes?.episodes ?? const <Episode>[];
    final remote = _remoteEpisode(episodes);
    return remote == null ? AppStrings.play : '继续观看 第${remote.index}集';
  }

  String get _qualityPref {
    final quality = AppScope.controllerOf(context).settings.defaultQuality;
    return quality == Quality.auto || quality.isEmpty ? 'auto' : quality;
  }

  Future<void> _play(Episode episode) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final plan = await widget.api.play(
        PlayRequest(
          itemId: widget.item.id,
          episodeId: episode.id,
          quality: _qualityPref,
        ),
      );
      if (!mounted) return;
      final episodes = _episodes?.episodes ?? const <Episode>[];
      final exit = await openFullPlayer(
        context,
        plan: plan,
        title: widget.item.title,
        api: widget.api,
        itemId: widget.item.id,
        episodes: episodes,
        episodeId: episode.id,
        cover: widget.item.cover,
      );
      // The player may have switched to another 作品系列: open that work's
      // detail, not the one this page was built for.
      if (!mounted || exit == null || !exit.wantsDetail) return;
      try {
        final current = await widget.api.detail(exit.itemId);
        if (mounted) {
          await openDetail(
            context,
            widget.api,
            current,
            poster: exit.cover,
          );
        }
      } on Object {
        // The player is already closed; keep the current detail page.
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeGatewayError(error))),
      );
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final item = _fresh ?? widget.item;
    final episodes = _episodes?.episodes ?? const <Episode>[];
    final poster = widget.poster.isNotEmpty
        ? widget.poster
        : (widget.item.cover.isNotEmpty ? widget.item.cover : item.cover);
    return PageTitleBinding(
      title: item.title.trim().isNotEmpty ? item.title : widget.item.title,
      hideInChrome: true,
      child: CoverBackdrop(
        cover: poster,
        child: ContentFrame(
        scrollable: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pendingInitial > 0)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.x2),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 880;
            final rail = _rail(context, item, poster, episodes);
            final main = _main(context, item, episodes);
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  rail,
                  const SizedBox(height: AppSpacing.x6),
                  main,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 224, child: rail),
                const SizedBox(width: AppSpacing.x8),
                Expanded(child: main),
              ],
            );
          },
        ),
          ],
        ),
      ),
      ),
    );
  }

  // ------------------------------------------------------------- left rail

  /// Poster, primary action, account actions and counters. Kept narrow so the
  /// title and episode sheet own the reading column.
  Widget _rail(
    BuildContext context,
    Item item,
    String poster,
    List<Episode> episodes,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = constraints.maxWidth.clamp(0.0, 208.0);
        final posterHeight = railWidth * 296 / 208;
        return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: railWidth,
          height: posterHeight,
          child: _Cover(
            cover: poster,
            title: item.title,
            width: railWidth,
            height: posterHeight,
          ),
        ),
        const SizedBox(height: AppSpacing.x4),
        SizedBox(
          width: railWidth,
          height: 44,
          child: FilledButton.icon(
            onPressed: episodes.isEmpty || _playing ? null : _playResume,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              textStyle: const TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w600,
              ),
            ),
            icon: _playing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow, size: 20),
            label: Text(
              _playLabel(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Row(
          children: [
            Expanded(
              child: _RailAction(
                icon: _favorite ? Icons.favorite : Icons.favorite_border,
                label: _favorite ? '已收藏' : '收藏',
                active: _favorite,
                onTap: _toggleFavorite,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: _RailAction(
                icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                label: _liked ? '已赞' : '点赞',
                active: _liked,
                onTap: _toggleLike,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: _RailAction(
                icon: _reserved
                    ? Icons.notifications_active
                    : Icons.notifications_none,
                label: _released
                    ? (_reserved ? '已追更' : '追更')
                    : (_reserved ? '已预约' : '预约'),
                active: _reserved,
                onTap: _toggleReservation,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Row(
          children: [
            Expanded(
              child: _RailAction(
                icon: Icons.share_outlined,
                label: '分享',
                onTap: _share,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: _RailAction(
                icon: Icons.download_outlined,
                label: '下载',
                onTap: episodes.isEmpty
                    ? null
                    : () => showDownloadSheet(
                          context,
                          api: widget.api,
                          item: item,
                          episodes: episodes,
                          cover: poster,
                        ),
              ),
            ),
          ],
        ),
      ],
        );
      },
    );
  }

  // ------------------------------------------------------------- main column

  Widget _main(BuildContext context, Item item, List<Episode> episodes) {
    final tokens = AppTokens.of(context);
    // Some detail payloads come back with an empty series_title/categories;
    // the list item that opened the page is the reliable fallback.
    final title = item.title.trim().isNotEmpty ? item.title : widget.item.title;
    final ownCategories = stringList(item.extra['categories']);
    final categories = ownCategories.isNotEmpty
        ? ownCategories
        : stringList(widget.item.extra['categories']);
    final description = item.description.isNotEmpty
        ? item.description
        : widget.item.description;
    final ownBadges = item.badges.isNotEmpty ? item.badges : widget.item.badges;
    // The tab already carries the episode count and the score has its own
    // cell, so those badges would repeat data.
    final badges = ownBadges
        .where((badge) => !RegExp(r'^共\d+集$').hasMatch(badge.trim()))
        .where((badge) => !RegExp(r'^\d+(\.\d+)?分$').hasMatch(badge.trim()))
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (categories.isNotEmpty)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x1,
            children: [
              for (var i = 0; i < categories.take(6).length; i++) ...[
                _CategoryLink(
                  label: categories[i],
                  onTap: () => openCategory(
                    context,
                    widget.api,
                    tags: [categories[i]],
                  ),
                ),
                if (i < categories.take(6).length - 1)
                  Text(
                    '·',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.text3,
                    ),
                  ),
              ],
            ],
          ),
        const SizedBox(height: AppSpacing.x2),
        SelectionArea(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 28,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: tokens.colors.text,
            ),
          ),
        ),
        if (badges.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.x2),
          AppBadgeRow(labels: badges, max: 4),
        ],
        if (description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.x3),
          Text(
            description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppFontSize.body,
              height: 1.7,
              color: tokens.colors.text2,
            ),
          ),
        ],
        _statStrip(context, item),
        const SizedBox(height: AppSpacing.x6),
        _DetailTabs(
          selected: _tab,
          onPick: _selectTab,
          episodeCount: episodes.length,
          seriesCount: _albumItems.length,
          commentCount: _commentCount,
          relatedCount: _related.length,
        ),
        const SizedBox(height: AppSpacing.x3),
        SizedBox(
          height: 500,
          child: _tabBody(context, episodes),
        ),
      ],
    );
  }

  /// Rating, heat, followers and plays in one strip. Counts live here only;
  /// the poster rail does not repeat them.
  Widget _statStrip(BuildContext context, Item item) {
    final labels = AppScope.controllerOf(context).uiManifest?.labels ??
        const <String, String>{};
    final score = _score;
    final scoreCount = _extraInt(item, 'score_count');
    final hot = _extraInt(item, 'hot_score');
    final follow = _extraInt(item, 'follow_count');
    final play = _extraInt(item, 'play_count');
    final cells = <Widget>[
      _ScoreCell(score: score, count: scoreCount),
      _StatCell(
        label: labels['detail.hot_label'] ?? '热度',
        value: hot > 0 ? formatCountPrecise(hot) : '—',
      ),
      _StatCell(
        label: labels['detail.follows_label'] ?? '追剧',
        value: formatCountPrecise(follow),
      ),
      _StatCell(
        label: labels['detail.plays_label'] ?? '播放',
        value: formatCountPrecise(play),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.x3),
      child: Wrap(
        spacing: AppSpacing.x6,
        runSpacing: AppSpacing.x2,
        children: [
          for (var i = 0; i < cells.length; i++)
            SizedBox(width: i == 0 ? 168 : 132, child: cells[i]),
        ],
      ),
    );
  }

  int _extraInt(Item item, String key) =>
      item.extra[key] is num ? (item.extra[key] as num).toInt() : 0;

  Widget _tabBody(BuildContext context, List<Episode> episodes) {
    switch (_tab) {
      case _tabSeries:
        return _seriesView(context);
      case _tabReviews:
        return _commentsView(context);
      case _tabRelated:
        return _relatedView(context);
      default:
        return SingleChildScrollView(
          child: _episodesView(context, episodes),
        );
    }
  }

  Widget _seriesView(BuildContext context) {
    if (_albumItems.isEmpty) {
      return const StatePanel(
        icon: Icons.collections_bookmark_outlined,
        title: '暂无作品系列',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _albumItems.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.x2),
      itemBuilder: (context, index) {
        final item = _albumItems[index];
        final current = item.extra['current'] == true;
        final online = item.extra['is_online'] != false;
        return AlbumRow(
          item: item,
          current: current,
          online: online,
          reserved: _reservedAlbum.contains(item.id),
          onTap: current || !online
              ? null
              : () => Navigator.of(context).push(
                    instantRoute(
                      (_) => OpaquePage(
                        child: DetailContent(item: item, api: widget.api),
                      ),
                    ),
                  ),
          onReserve: online ? null : () => _reserveAlbumItem(item),
        );
      },
    );
  }

  Widget _relatedView(BuildContext context) {
    if (_related.isEmpty) {
      final labels = AppScope.controllerOf(context).uiManifest?.labels ??
          const <String, String>{};
      return StatePanel(
        icon: Icons.movie_filter_outlined,
        title: labels['detail.related_empty'] ?? '暂无相关内容',
      );
    }
    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: AppSpacing.x4,
        crossAxisSpacing: AppSpacing.x4,
        childAspectRatio: AppSizes.posterAspect,
      ),
      itemCount: _related.length,
      itemBuilder: (context, index) {
        final related = _related[index];
        return PosterCard(
          item: related,
          onTap: () => Navigator.of(context).push(
            instantRoute(
              (_) => OpaquePage(
                child: DetailContent(item: related, api: widget.api),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _commentsView(BuildContext context) {
    final tokens = AppTokens.of(context);
    if (_commentsLoading) {
      return const LoadingView(skeleton: SkeletonList());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _comments.isEmpty ? '还没有剧评' : '全部剧评',
              style: TextStyle(fontSize: AppFontSize.body, color: tokens.colors.text3),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _openComments,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('写剧评'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Expanded(
          child: _commentsError != null && _comments.isEmpty
              ? StatePanel(
                  icon: Icons.error_outline,
                  title: AppStrings.errorTitle,
                  body: _commentsError!,
                  action: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _commentsError = null;
                        _commentsLoaded = false;
                        _commentNext = '';
                      });
                      unawaited(_loadComments());
                    },
                    child: const Text(AppStrings.retry),
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.extentAfter < 400) {
                      unawaited(_loadComments(more: true));
                    }
                    return false;
                  },
                  child: ListView.separated(
                  controller: _commentsScroll,
                  padding: EdgeInsets.zero,
                  itemCount: _comments.length + (_commentsLoadingMore ? 1 : 0),
                  separatorBuilder: (_, __) => Divider(
                    height: AppSpacing.x6,
                    color: tokens.colors.border,
                  ),
                  itemBuilder: (context, index) {
                    if (index >= _comments.length) {
                      return const Padding(
                        padding: EdgeInsets.all(AppSpacing.x4),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return _ReviewRow(comment: _comments[index]);
                  },
                ),
                ),
        ),
      ],
    );
  }

  Widget _episodesView(BuildContext context, List<Episode> episodes) {
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.x2),
            child: LoadingLine(compact: true),
          ),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: List.generate(
              12,
              (index) => const SkeletonBox(
                  width: 64, height: 34, radius: AppRadius.sm),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return StatePanel(
        icon: Icons.error_outline,
        title: AppStrings.errorTitle,
        body: describeGatewayError(_error!),
        action: OutlinedButton(
          onPressed: _loadEpisodes,
          child: const Text(AppStrings.retry),
        ),
      );
    }
    if (episodes.isEmpty) {
      return const StatePanel(
        icon: Icons.video_library_outlined,
        title: AppStrings.noEpisodes,
      );
    }
    final chunks = <Widget>[];
    for (var start = 0; start < episodes.length; start += 50) {
      final end =
          start + 50 > episodes.length ? episodes.length : start + 50;
      if (start > 0) chunks.add(const SizedBox(height: AppSpacing.x4));
      chunks.add(
        Text(
          '${start + 1}-$end',
          style: TextStyle(
            fontSize: AppFontSize.xxs,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: AppTokens.of(context).colors.text3,
          ),
        ),
      );
      chunks.add(const SizedBox(height: AppSpacing.x2));
      chunks.add(
        Wrap(
          spacing: AppSpacing.x2,
          runSpacing: AppSpacing.x2,
          children: [
            for (final episode in episodes.sublist(start, end))
              _EpisodeChip(
                episode: episode,
                watched: _watched(episode),
                onTap: () => _play(episode),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: chunks,
    );
  }
}

class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    required this.episode,
    required this.watched,
    required this.onTap,
  });

  final Episode episode;
  final bool watched;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final label = episode.title.isEmpty ? '${episode.index}' : episode.title;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 84,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: watched
              ? tokens.colors.accentWeak
              : tokens.colors.surface2.withValues(alpha: 0.48),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: watched
                ? tokens.colors.accent.withValues(alpha: 0.45)
                : tokens.colors.border.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (watched) ...[
              Icon(Icons.check, size: 12, color: tokens.colors.accent),
              const SizedBox(width: 2),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  color: watched ? tokens.colors.accent : tokens.colors.text2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.cover,
    required this.title,
    required this.width,
    required this.height,
  });

  final String cover;
  final String title;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? AppShadows.dark
            : AppShadows.light,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: CoverImage(
          url: cover,
          seed: title,
          decodeWidth: 400,
          radius: AppRadius.md,
        ),
      ),
    );
  }
}

/// Inline category link above the title. No chip: the text itself is the
/// affordance, separated by middots.
class _CategoryLink extends StatefulWidget {
  const _CategoryLink({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_CategoryLink> createState() => _CategoryLinkState();
}

class _CategoryLinkState extends State<_CategoryLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: AppFontSize.xs,
              fontWeight: FontWeight.w600,
              color: _hovered
                  ? tokens.colors.accent
                  : tokens.colors.accent.withValues(alpha: 0.82),
              decoration:
                  _hovered ? TextDecoration.underline : TextDecoration.none,
              decorationColor: tokens.colors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small icon-over-label action in the poster rail.
class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final color = onTap == null
        ? tokens.colors.text3
        : active
            ? tokens.colors.accent
            : tokens.colors.text2;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.xxs,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rating with a score band: ≥8 green, 5–8 amber, <5 red.
class _ScoreCell extends StatelessWidget {
  const _ScoreCell({required this.score, required this.count});

  final String score;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final value = double.tryParse(score);
    final color = value == null
        ? tokens.colors.text3
        : value > 8
            ? tokens.colors.badgeNew
            : value >= 5
                ? tokens.colors.badgeGold
                : tokens.colors.danger;
    final display = score.trim().isEmpty ? '—' : score.trim();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: value == null ? 0.06 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: color.withValues(alpha: value == null ? 0.18 : 0.34),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '评分',
            style: TextStyle(
              fontSize: AppFontSize.xxs,
              color: tokens.colors.text3,
            ),
          ),
          const SizedBox(height: 1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                display,
                style: TextStyle(
                  fontSize: 26,
                  height: 1.05,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              if (display != '—')
                Text(
                  ' 分',
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
            ],
          ),
          if (count > 0)
            Text(
              '$count人评分',
              style: TextStyle(
                fontSize: AppFontSize.xxs,
                color: tokens.colors.text3,
              ),
            ),
        ],
      ),
    );
  }
}

/// One metric in the rating/heat/followers/plays strip.
class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.xxs,
            color: tokens.colors.text3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: AppFontSize.title,
            fontWeight: FontWeight.w700,
            color: tokens.colors.text,
          ),
        ),
      ],
    );
  }
}

/// The detail page's content surfaces; every label comes from the source.
class _DetailTabs extends StatelessWidget {
  const _DetailTabs({
    required this.selected,
    required this.onPick,
    required this.episodeCount,
    required this.seriesCount,
    required this.commentCount,
    required this.relatedCount,
  });

  final int selected;
  final ValueChanged<int> onPick;
  final int episodeCount;
  final int seriesCount;
  final int commentCount;
  final int relatedCount;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final labels = AppScope.controllerOf(context).uiManifest?.labels ??
        const <String, String>{};
    final tabs = <(String, int)>[
      (labels['detail.tab.episodes'] ?? '选集', episodeCount),
      (labels['detail.tab.series'] ?? '系列', seriesCount),
      (labels['detail.tab.reviews'] ?? '剧评', commentCount),
      (labels['detail.tab.related'] ?? '相关', relatedCount),
    ];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: tokens.colors.border),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            InkWell(
              onTap: () => onPick(i),
              mouseCursor: SystemMouseCursors.click,
              child: Container(
                margin: const EdgeInsets.only(right: AppSpacing.x6),
                padding: const EdgeInsets.only(bottom: AppSpacing.x2),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected == i
                          ? tokens.colors.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      tabs[i].$1,
                      style: TextStyle(
                        fontSize: AppFontSize.bodyLg,
                        fontWeight:
                            selected == i ? FontWeight.w700 : FontWeight.w500,
                        color: selected == i
                            ? tokens.colors.text
                            : tokens.colors.text2,
                      ),
                    ),
                    if (tabs[i].$2 > 0) ...[
                      const SizedBox(width: AppSpacing.x1),
                      Text(
                        '${tabs[i].$2}',
                        style: TextStyle(
                          fontSize: AppFontSize.xxs,
                          color: tokens.colors.text3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}

/// One 剧评 row in the detail page (read-only; replying happens in the sheet).
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: tokens.colors.surface3,
          backgroundImage: comment.avatar.isEmpty
              ? null
              : NetworkImage(comment.avatar),
          child: comment.avatar.isEmpty
              ? Text(
                  comment.userName.isEmpty ? '?' : comment.userName.characters.first,
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    color: tokens.colors.text2,
                  ),
                )
              : null,
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      comment.userName.isEmpty ? '匿名用户' : comment.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppFontSize.xs,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ),
                  if (comment.likeCount > 0)
                    Row(
                      children: [
                        Icon(
                          comment.liked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 14,
                          color: comment.liked
                              ? tokens.colors.accent
                              : tokens.colors.text3,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${comment.likeCount}',
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                renderEmoji(comment.text),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.body,
                  height: AppLineHeight.body,
                  color: tokens.colors.text2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
