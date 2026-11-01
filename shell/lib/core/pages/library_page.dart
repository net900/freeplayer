import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../downloads/download_manager.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../library/local_library.dart';
import '../local/local_media.dart';
import '../sp/models.dart';
import '../storage/paths.dart';
import '../sp/quality.dart';
import '../sp/page_types.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';
import '../widgets/editorial.dart';
import 'common.dart';
import 'likes_view.dart';
import 'loading.dart';
import 'login_sheet.dart';
import 'navigation.dart';
import 'poster_card.dart';
import 'player_page.dart';
import 'resume.dart';
import 'route.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.type,
  });

  final String type;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

String _timeLabel(String raw) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _LibraryPageState extends State<LibraryPage> {
  Future<List<LibraryRecord>>? _records;
  Future<ItemPage>? _remote;
  bool _didInit = false;
  int _historyFilter = 0; // 0 全部, 1 未看完, 2 已看完
  int _savedTab = 0; // 收藏页: 0 收藏, 1 点赞
  bool _likesSelecting = false;
  final GlobalKey<LikesViewState> _likesKey = GlobalKey<LikesViewState>();
  int _likesReload = 0;
  bool _selectingRecords = false;
  final Set<String> _selectedRecords = {};
  bool _selectingRemote = false;
  final Set<String> _selectedRemote = {};
  List<Item> _lastRemoteItems = const [];
  List<LibraryRecord> _lastRecords = const [];
  int _followTab = 0; // 0 追更, 1 预约待上线, 2 预约已上线
  final Map<int, Future<ItemPage>?> _reservationPages = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _startLoad();
  }

  void _reload() {
    setState(() {
      _likesReload++;
      _startLoad();
    });
  }

  /// 点赞 has its own selection inside LikesView.
  bool get _supportsRecordSelection =>
      (widget.type == PageTypes.libraryHistory ||
          (widget.type == PageTypes.libraryFavorites && _savedTab == 0));

  Future<void> _deleteSelectedRecords() async {
    final keys = {..._selectedRecords};
    if (keys.isEmpty) return;
    final library = AppScope.of(context).library;
    final api = AppScope.of(context).controller.sourceApi;
    if (widget.type == PageTypes.libraryHistory) {
      await library.removeHistory(keys);
    } else {
      await library.removeFavorites(keys);
      if (api != null) {
        for (final record in _lastRecords) {
          if (!keys.contains(record.seriesKey) || record.itemId.isEmpty) {
            continue;
          }
          try {
            await api.setFavorite(record.itemId, false);
          } on Object {
            // Local removal already succeeded; the shelf syncs next time.
          }
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _selectingRecords = false;
      _selectedRecords.clear();
    });
    _reload();
  }

  void _startLoad() {
    final library = AppScope.of(context).library;
    // 下载 is driven by DownloadManager; nothing to prefetch here.
    if (widget.type == PageTypes.libraryDownloads) return;
    if ((widget.type == PageTypes.libraryFavorites && _savedTab == 1) ||
        widget.type == PageTypes.libraryLikes) {
      // LikesView owns its paging; nothing to prefetch here.
      _records = null;
      _remote = null;
    } else if (_isRemoteList) {
      _records = null;
      final api = AppScope.of(context).controller.sourceApi;
      _remote = _remotePage(api);
    } else {
      _records = _loadRecords(library);
    }
  }

  bool get _isRemoteList =>
      widget.type == PageTypes.libraryFollow ||
      widget.type == PageTypes.libraryReservations;

  Future<ItemPage>? _remotePage(SourceApi? api) {
    if (api == null) return null;
    switch (widget.type) {
      case PageTypes.libraryFollow:
        return _fetchAll((cursor) => api.follows(cursor: cursor, limit: 50));
      case PageTypes.libraryReservations:
        return api.reservations(limit: 50);
      case PageTypes.libraryLikes:
        return _fetchAll((cursor) => api.likes(cursor: cursor, limit: 50));
    }
    return null;
  }

  Future<void> _openRecord(LibraryRecord record) async {
    final api = AppScope.of(context).controller.sourceApi;
    if (api == null || record.itemId.isEmpty) return;
    await openDetail(
      context,
      api,
      Item(
        id: record.itemId,
        title: record.title,
        cover: record.cover,
        type: 'series',
        extra: {'vid': record.episodeId},
      ),
    );
  }

  Future<void> _deleteReservation(SourceApi api, Item item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消预约'),
        content: Text('不再等待《${item.title}》上线？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消预约'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final reserveID = str(item.extra['reserve_id']);
    final online = item.extra['is_online'] == true;
    try {
      await api.deleteReservations(
        [reserveID.isEmpty ? item.id : reserveID],
        online: online,
      );
      if (!mounted) return;
      _reload();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeGatewayError(error))),
      );
    }
  }

  /// Pulls every page so client-side category tabs see the whole list.
  Future<ItemPage> _fetchAll(
    Future<ItemPage> Function(String cursor) fetch, {
    int maxPages = 10,
  }) async {
    final items = <Item>[];
    var cursor = '';
    for (var page = 0; page < maxPages; page++) {
      final result = await fetch(cursor);
      items.addAll(result.items);
      if (result.next.isEmpty) break;
      cursor = result.next;
    }
    return ItemPage(items: items);
  }

  Future<List<LibraryRecord>> _loadRecords(LocalLibrary library) async {
    final favorites = widget.type == PageTypes.libraryFavorites;
    // Resolve the scope before awaiting (the element may be gone afterwards).
    final controller = AppScope.of(context).controller;
    final api = controller.sourceApi;
    // History and favourites belong to one source: local mode and each
    // connected source keep their own shelf.
    final scope = controller.localMode || api == null ? 'local' : api.sourceId;
    final hidden = favorites
        ? await library.hiddenFavorites()
        : await library.hiddenHistory();
    final local = (favorites
            ? await library.favorites()
            : await library.history())
        .where((record) => record.sourceId == scope)
        .where((record) => !hidden.contains(record.seriesKey))
        .toList(growable: false);
    if (api == null || widget.type == PageTypes.libraryDownloads) return local;
    try {
      final page = favorites
          ? await api.favorites(cursor: '', limit: 50)
          : await api.history(limit: 50);
      final merged = <String, LibraryRecord>{
        for (final record in local) record.seriesKey: record,
      };
      final localKeys = merged.keys.toSet();
      final remoteKeys = <String>{};
      for (final item in page.items) {
        final key = '${api.sourceId}:${item.id}';
        if (hidden.contains(key)) continue;
        remoteKeys.add(key);
        final existing = merged[key];
        if (existing != null) {
          if (widget.type == PageTypes.libraryHistory &&
              existing.episodeId.isEmpty) {
            merged[key] = _remoteRecord(api.sourceId, item, existing);
          } else {
            // The account shelf carries the current artwork; a record saved
            // from a list or a player frame can hold an older cover.
            merged[key] = existing.copyWith(
              title: item.title.trim().isEmpty ? null : item.title,
              cover: item.cover.trim().isEmpty ? null : item.cover,
            );
          }
          continue;
        }
        merged[key] = _remoteRecord(api.sourceId, item, null);
      }
      if (favorites) return merged.values.toList(growable: false);
      // Only this device knows how far an episode really was played; the
      // upstream history duration is not a per-episode length.
      final positions = await library.episodeProgress();
      return merged.values.map((record) {
        final local = positions['${record.seriesKey}|${record.episodeId}'];
        if (local != null) {
          return record.copyWith(
            positionSec: local.position,
            durationSec: local.duration,
            finished: local.position >= local.duration - 3,
          );
        }
        if (remoteKeys.contains(record.seriesKey) &&
            !localKeys.contains(record.seriesKey)) {
          // The account's duration is not a per-episode length; without a
          // local position the bar would be fiction.
          return record.copyWith(positionSec: 0, durationSec: 0);
        }
        return record;
      }).toList(growable: false);
    } on Object {
      return local;
    }
  }

  LibraryRecord _remoteRecord(String sourceId, Item item, LibraryRecord? base) {
    final extra = item.extra;
    final episodeId = str(extra['vid']);
    return LibraryRecord(
      seriesKey: '$sourceId:${item.id}',
      title: item.title,
      cover: item.cover,
      sourceId: sourceId,
      itemId: item.id,
      episodeId: episodeId,
      episodeIndex: intOr(extra['vid_index']),
      positionSec: intOr(extra['position_sec']),
      durationSec: intOr(extra['duration_sec']),
      updatedAt: base?.updatedAt ?? '',
      episodeCount: intOr(extra['episode_count']) > 0
          ? intOr(extra['episode_count'])
          : item.episodeCount,
      finished: extra['finished'] == true,
      category: str(extra['category']),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(title: _title),
          // The page actions sit at the end of the tab row so they do not
          // claim a line of their own.
          if (widget.type == PageTypes.libraryHistory)
            UnderlineTabBar(
              labels: const ['全部', '未看完', '已看完'],
              selected: _historyFilter,
              onPick: (value) => setState(() => _historyFilter = value),
              trailing: _pageActions,
            ),
          if (widget.type == PageTypes.libraryFavorites)
            UnderlineTabBar(
              labels: const ['收藏', '点赞'],
              selected: _savedTab,
              onPick: (value) {
                // The old selection belongs to the previous list; keeping it
                // would let 批量删除 act on ids that are no longer shown.
                setState(() {
                  _savedTab = value;
                  _selectingRecords = false;
                  _selectedRecords.clear();
                });
                _reload();
              },
              trailing: _pageActions,
            ),
          if (widget.type == PageTypes.libraryFollow)
            UnderlineTabBar(
              labels: const ['追更', '待上线', '已上线'],
              selected: _followTab,
              onPick: (value) {
                setState(() {
                  _followTab = value;
                  _selectingRemote = false;
                  _selectedRemote.clear();
                });
                if (value > 0) _loadReservationState(value == 2);
              },
              trailing: _pageActions,
            ),
          if (widget.type == PageTypes.libraryDownloads)
            Align(
              alignment: Alignment.centerRight,
              child: _pageActions,
            ),
          if (_selectingRemote) _remoteBatchBar(),
          if (_selectingRecords)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.x2,
                bottom: AppSpacing.x3,
              ),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      final all = _lastRecords.map((r) => r.seriesKey).toSet();
                      if (_selectedRecords.length == all.length) {
                        _selectedRecords.clear();
                      } else {
                        _selectedRecords
                          ..clear()
                          ..addAll(all);
                      }
                    }),
                    child: Text(
                      _selectedRecords.length == _lastRecords.length
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _selectedRecords.isEmpty
                        ? null
                        : _deleteSelectedRecords,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text('删除 ${_selectedRecords.length}'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.of(context).colors.danger,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _body(context)),
        ],
      ),
      );
  }

  Widget _remoteBatchBar() {
    final tokens = AppTokens.of(context);
    final items = _lastRemoteItems;
    final allSelected =
        items.isNotEmpty && _selectedRemote.length == items.length;
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.x2,
        bottom: AppSpacing.x3,
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (allSelected) {
                _selectedRemote.clear();
              } else {
                _selectedRemote
                  ..clear()
                  ..addAll(items.map((item) => item.id));
              }
            }),
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _selectedRemote.isEmpty ? null : _deleteSelectedRemote,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: Text('删除 ${_selectedRemote.length}'),
            style: FilledButton.styleFrom(
              backgroundColor: tokens.colors.danger,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelectedRemote() async {
    final api = AppScope.of(context).controller.sourceApi;
    final ids = _selectedRemote.toList(growable: false);
    if (api == null || ids.isEmpty) return;
    try {
      if (widget.type == PageTypes.libraryFollow && _followTab == 0) {
        for (final id in ids) {
          await api.setFollow(id, false);
        }
      } else {
        final online = widget.type == PageTypes.libraryReservations ||
            _followTab == 2;
        // The reservation delete takes the reservation id when the source
        // exposes one, otherwise the series id.
        final targets = <String>[
          for (final item in _lastRemoteItems)
            if (ids.contains(item.id))
              str(item.extra['reserve_id']).isEmpty
                  ? item.id
                  : str(item.extra['reserve_id']),
        ];
        await api.deleteReservations(
          targets.isEmpty ? ids : targets,
          online: online,
        );
      }
      if (!mounted) return;
      setState(() {
        _selectedRemote.clear();
        _selectingRemote = false;
        if (_reservationPages.isNotEmpty) _reservationPages.clear();
      });
      _remote = _remotePage(api);
    } on Object catch (error) {
      if (!mounted) return;
      _snack(describeGatewayError(error));
    }
  }

  Future<void> _unfollow(SourceApi api, Item item) async {
    try {
      await api.setFollow(item.id, false);
      if (!mounted) return;
      setState(() => _remote = _remotePage(api));
    } on Object catch (error) {
      if (mounted) _snack(describeGatewayError(error));
    }
  }

  Widget get _pageActions => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_supportsRecordSelection)
            IconButton(
              tooltip: _selectingRecords ? '取消' : '批量管理',
              onPressed: () => setState(() {
                _selectingRecords = !_selectingRecords;
                _selectedRecords.clear();
              }),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints:
                  const BoxConstraints.tightFor(width: 32, height: 32),
              icon: Icon(
                _selectingRecords ? Icons.close : Icons.checklist,
                size: 18,
              ),
            ),
          if (widget.type == PageTypes.libraryFavorites && _savedTab == 1)
            TextButton(
              onPressed: () => _likesKey.currentState?.toggleSelecting(),
              child: Text(_likesSelecting ? '取消' : '批量'),
            ),
          if (widget.type == PageTypes.libraryFollow ||
              widget.type == PageTypes.libraryReservations)
            TextButton(
              onPressed: () => setState(() {
                _selectingRemote = !_selectingRemote;
                _selectedRemote.clear();
              }),
              child: Text(_selectingRemote ? '取消' : '批量'),
            ),
          if (widget.type == PageTypes.libraryDownloads)
            IconButton(
              tooltip: '打开下载目录',
              onPressed: _openDownloadsFolder,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: const Icon(Icons.folder_open, size: 18),
            ),
          if (widget.type == PageTypes.libraryDownloads)
            TextButton(
              onPressed: _clearDownloads,
              child: const Text('清空'),
            ),
          IconButton(
            tooltip: AppStrings.reload,
            onPressed: _reload,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 32, height: 36),
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      );

  String get _title {
    switch (widget.type) {
      case PageTypes.libraryHistory:
        return AppStrings.navHistory;
      case PageTypes.libraryFavorites:
        return AppStrings.navFavorites;
      case PageTypes.libraryFollow:
        return AppStrings.navFollow;
      case PageTypes.libraryReservations:
        return AppStrings.navReservations;
      case PageTypes.libraryLikes:
        return AppStrings.navLikes;
      case PageTypes.libraryDownloads:
        return AppStrings.navDownloads;
      default:
        return AppStrings.navLibrary;
    }
  }

  Widget _body(BuildContext context) {
    if (widget.type == PageTypes.libraryFollow && _followTab > 0) {
      return _reservationBody(context, online: _followTab == 2);
    }
    if (widget.type == PageTypes.libraryLikes ||
        (widget.type == PageTypes.libraryFavorites && _savedTab == 1)) {
      return _likesBody(context);
    }
    if (_isRemoteList) {
      return _remoteBody(context);
    }
    if (widget.type == PageTypes.libraryDownloads) {
      return _downloadsBody(context);
    }
    return _recordsBody(context);
  }

  Widget _likesBody(BuildContext context) {
    final api = AppScope.of(context).controller.sourceApi;
    if (api == null) {
      return const StatePanel(
        icon: Icons.thumb_up_outlined,
        title: '点赞需要连接内容源',
      );
    }
    return KeyedSubtree(
      key: ValueKey('likes-$_likesReload-${widget.type}-$_savedTab'),
      child: LikesView(
        key: _likesKey,
        api: api,
        onOpenDetail: (item) => openDetail(context, api, item),
        onPlayEpisode: (item) => _playEpisode(context, api, item),
        onSelectingChanged: (value) => setState(() => _likesSelecting = value),
      ),
    );
  }

  Widget _remoteBody(BuildContext context) {
    final future = _remote;
    final icon = _remoteIcon;
    if (future == null) {
      return StatePanel(icon: icon, title: '${_remoteLabel}需要登录');
    }
    final api = AppScope.of(context).controller.sourceApi;
    return FutureBuilder<ItemPage>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingView(skeleton: SkeletonList());
        }
        final error = snapshot.error;
        if (error is SpException && error.code == SpErrorCode.unauthorized) {
          return StatePanel(
            icon: icon,
            title: '${_remoteLabel}需要登录',
            body: '登录账号后，这里显示你的${_remoteLabel}记录。',
            action: FilledButton(
              onPressed: () async {
                if (api == null) return;
                final ok = await showLoginSheet(context, api: api);
                if (ok && mounted) _reload();
              },
              child: const Text('登录'),
            ),
          );
        }
        if (snapshot.hasError) {
          return StatePanel(
            icon: Icons.error_outline,
            title: AppStrings.errorTitle,
            body: describeGatewayError(snapshot.error!),
            action: OutlinedButton(
              onPressed: _reload,
              child: const Text(AppStrings.retry),
            ),
          );
        }
        final page = snapshot.data;
        if (page == null || page.items.isEmpty) {
          return StatePanel(icon: icon, title: '还没有$_remoteLabel记录');
        }
        final items = page.items;
        if (items.isEmpty) {
          return StatePanel(icon: icon, title: '还没有$_remoteLabel记录');
        }
        if (widget.type == PageTypes.libraryReservations) {
          _lastRemoteItems = page.items;
          return ItemGrid(
            children: [
              for (final item in page.items)
                Stack(
                  children: [
                    PosterCard(
                      item: item,
                      onTap: api == null
                          ? null
                          : _selectingRemote
                              ? () => setState(() {
                                    if (!_selectedRemote.remove(item.id)) {
                                      _selectedRemote.add(item.id);
                                    }
                                  })
                              : () => openDetail(context, api, item),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _selectingRemote
                          ? _SelectDot(
                              selected: _selectedRemote.contains(item.id),
                              onTap: () => setState(() {
                                if (!_selectedRemote.remove(item.id)) {
                                  _selectedRemote.add(item.id);
                                }
                              }),
                            )
                          : Material(
                              color: Colors.black54,
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: '取消预约',
                                iconSize: 16,
                                visualDensity: VisualDensity.compact,
                                color: Colors.white,
                                onPressed: api == null
                                    ? null
                                    : () => _deleteReservation(api, item),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                    ),
                  ],
                ),
            ],
          );
        }
        _lastRemoteItems = items;
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: items.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: AppSpacing.x2),
          itemBuilder: (context, index) {
            final item = items[index];
            return _FollowRow(
              item: item,
              selecting: _selectingRemote,
              selected: _selectedRemote.contains(item.id),
              onTap: _selectingRemote
                  ? () => setState(() {
                        if (!_selectedRemote.remove(item.id)) {
                          _selectedRemote.add(item.id);
                        }
                      })
                  : api == null
                      ? null
                      : () => openDetail(context, api, item),
              onUnfollow: api == null || _selectingRemote
                  ? null
                  : () => _unfollow(api, item),
            );
          },
        );
      },
    );
  }

  /// A like row is one episode: start exactly that vid, with the series rail.
  Future<void> _playEpisode(BuildContext context, SourceApi api, Item item) async {
    final vid = str(item.extra['vid']);
    if (vid.isEmpty) {
      openDetail(context, api, item);
      return;
    }
    try {
      final quality = AppScope.controllerOf(context).settings.defaultQuality;
      final plan = await api.play(PlayRequest(
        itemId: item.id,
        episodeId: vid,
        quality: quality == Quality.auto ? 'auto' : quality,
      ));
      if (!mounted) return;
      var episodes = const <Episode>[];
      try {
        final page = await api.episodes(item.id);
        episodes = page.episodes;
      } on Object {
        // The single episode still plays without the rail.
      }
      if (!mounted) return;
      final exit = await openFullPlayer(
        context,
        plan: plan,
        title: item.title,
        api: api,
        itemId: item.id,
        episodes: episodes,
        episodeId: vid,
        cover: item.cover,
      );
      if (!mounted) return;
      if (exit?.wantsDetail == true) {
        try {
          final shown = await api.detail(exit!.itemId);
          if (mounted) {
            await openDetail(context, api, shown, poster: exit.cover);
          }
        } on Object {
          // The player is already closed; keep the list as it is.
        }
      }
      if (mounted) _reload();
    } on Object catch (error) {
      if (!mounted) return;
      _snack(describeGatewayError(error));
    }
  }

  void _loadReservationState(bool online) {
    final key = online ? 2 : 1;
    if (_reservationPages.containsKey(key)) return;
    final api = AppScope.of(context).controller.sourceApi;
    _reservationPages[key] =
        api?.reservations(limit: 50, online: online);
  }

  Future<void> _cancelReservation(
    SourceApi api,
    Item item,
    int key,
    bool online,
  ) async {
    await _deleteReservation(api, item);
    if (!mounted) return;
    setState(() => _reservationPages.remove(key));
    _loadReservationState(online);
    setState(() {});
  }

  Widget _reservationBody(BuildContext context, {required bool online}) {
    final key = online ? 2 : 1;
    _loadReservationState(online);
    final future = _reservationPages[key];
    final api = AppScope.of(context).controller.sourceApi;
    final label = online ? '已上线' : '待上线';
    return FutureBuilder<ItemPage>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingView(skeleton: SkeletonList());
        }
        final error = snapshot.error;
        if (error is SpException && error.code == SpErrorCode.unauthorized) {
          return StatePanel(
            icon: Icons.event_available_outlined,
            title: '预约需要登录',
            action: FilledButton(
              onPressed: () async {
                if (api == null) return;
                final ok = await showLoginSheet(context, api: api);
                if (ok && mounted) {
                  setState(() => _reservationPages.remove(key));
                  _loadReservationState(online);
                  setState(() {});
                }
              },
              child: const Text('登录'),
            ),
          );
        }
        if (snapshot.hasError) {
          return StatePanel(
            icon: Icons.error_outline,
            title: AppStrings.errorTitle,
            body: describeGatewayError(snapshot.error!),
            action: OutlinedButton(
              onPressed: () {
                setState(() => _reservationPages.remove(key));
                _loadReservationState(online);
                setState(() {});
              },
              child: const Text(AppStrings.retry),
            ),
          );
        }
        final items = snapshot.data?.items ?? const <Item>[];
        if (items.isEmpty) {
          return StatePanel(
            icon: Icons.event_available_outlined,
            title: '没有$label的预约',
          );
        }
        _lastRemoteItems = items;
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: items.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: AppSpacing.x2),
          itemBuilder: (context, index) {
            final item = items[index];
            return _ReservationRow(
              item: item,
              online: online,
              selecting: _selectingRemote,
              selected: _selectedRemote.contains(item.id),
              onOpen: api == null
                  ? null
                  : _selectingRemote
                      ? () => setState(() {
                            if (!_selectedRemote.remove(item.id)) {
                              _selectedRemote.add(item.id);
                            }
                          })
                      : () => openDetail(context, api, item),
              onCancel: api == null || _selectingRemote
                  ? null
                  : () => _cancelReservation(api, item, key, online),
            );
          },
        );
      },
    );
  }

  String get _remoteLabel {
    switch (widget.type) {
      case PageTypes.libraryReservations:
        return '预约';
      case PageTypes.libraryLikes:
        return '点赞';
    }
    return '追更';
  }

  IconData get _remoteIcon {
    switch (widget.type) {
      case PageTypes.libraryReservations:
        return Icons.event_available_outlined;
      case PageTypes.libraryLikes:
        return Icons.thumb_up_outlined;
    }
    return Icons.person_outline;
  }

  Widget _recordsBody(BuildContext context) {
    final future = _records;
    if (future == null) {
      return const StatePanel(
        icon: Icons.inbox_outlined,
        title: AppStrings.emptyTitle,
      );
    }
    return FutureBuilder<List<LibraryRecord>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingView(skeleton: SkeletonList());
        }
        if (snapshot.hasError) {
          return StatePanel(
            icon: Icons.error_outline,
            title: AppStrings.errorTitle,
            body: describeGatewayError(snapshot.error!),
            action: OutlinedButton(
              onPressed: _reload,
              child: const Text(AppStrings.retry),
            ),
          );
        }
        final all = snapshot.data ?? const <LibraryRecord>[];
        var records = widget.type == PageTypes.libraryHistory
            ? all.where((record) {
                if (_historyFilter == 1) return !_recordFinished(record);
                if (_historyFilter == 2) return _recordFinished(record);
                return true;
              }).toList(growable: false)
            : all;
        _lastRecords = records;
        if (records.isEmpty) {
          return StatePanel(
            icon: widget.type == PageTypes.libraryFavorites
                ? Icons.favorite_border
                : Icons.history,
            title: AppStrings.emptyTitle,
            body: widget.type == PageTypes.libraryFavorites
                ? AppStrings.favoritesEmptyBody
                : AppStrings.historyEmptyBody,
          );
        }
        if (widget.type == PageTypes.libraryFavorites) {
          return _favoriteGrid(context, records);
        }
        return _historyBody(context, records);
      },
    );
  }

  void _toggleRecordSelection(LibraryRecord record) {
    setState(() {
      if (!_selectedRecords.remove(record.seriesKey)) {
        _selectedRecords.add(record.seriesKey);
      }
    });
  }

  Widget _favoriteGrid(
    BuildContext context,
    List<LibraryRecord> records,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.x1),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: AppSpacing.x4,
        crossAxisSpacing: AppSpacing.x4,
        childAspectRatio: AppSizes.posterAspect,
      ),
      itemCount: records.length,
      itemBuilder: (context, index) {
        final record = records[index];
        final selected = _selectedRecords.contains(record.seriesKey);
        final item = Item(
          id: record.itemId,
          title: record.title,
          cover: record.cover,
          type: 'series',
          extra: {if (record.episodeId.isNotEmpty) 'vid': record.episodeId},
        );
        return Stack(
          children: [
            PosterCard(
              item: item,
              onTap: _selectingRecords
                  ? () => _toggleRecordSelection(record)
                  : () => _openRecord(record),
            ),
            if (_selectingRecords)
              Positioned(
                top: AppSpacing.x1,
                right: AppSpacing.x1,
                child: _SelectDot(
                  selected: selected,
                  onTap: () => _toggleRecordSelection(record),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _historyBody(
    BuildContext context,
    List<LibraryRecord> records,
  ) {
    final sorted = [...records]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final hero = _selectingRecords || sorted.isEmpty ? null : sorted.first;
    final rest = hero == null ? sorted : sorted.skip(1);
    final groups = <String, List<LibraryRecord>>{};
    for (final record in rest) {
      groups.putIfAbsent(_dateLabel(record.updatedAt), () => []).add(record);
    }
    final children = <Widget>[];
    // Local files carry no artwork: their history rows are text only.
    final showCover = !AppScope.controllerOf(context).localMode;
    if (hero != null) {
      children.add(
        _HistoryHero(
          record: hero,
          showCover: showCover,
          onResume: () => _resume(hero),
          onOpen: () => _openRecord(hero),
        ),
      );
    }
    for (final entry in groups.entries) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.x3,
            bottom: AppSpacing.x1,
          ),
          child: Text(
            entry.key,
            style: TextStyle(
              fontSize: AppFontSize.xxs,
              fontWeight: FontWeight.w600,
              color: AppTokens.of(context).colors.text3,
            ),
          ),
        ),
      );
      for (final record in entry.value) {
        final selected = _selectedRecords.contains(record.seriesKey);
        children.add(
          _RecordTile(
            record: record,
            showCover: showCover,
            showProgress: true,
            selecting: _selectingRecords,
            selected: selected,
            onToggleSelect: () => _toggleRecordSelection(record),
            onTap: _selectingRecords
                ? () => _toggleRecordSelection(record)
                : () => _resume(record),
            trailing: _selectingRecords
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '删除记录',
                        onPressed: () => _deleteHistoryRecord(record),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                        ),
                      ),
                      IconButton(
                        tooltip: AppStrings.play,
                        onPressed: () => _resume(record),
                        icon: const Icon(Icons.play_arrow, size: 20),
                      ),
                    ],
                  ),
          ),
        );
      }
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: children,
    );
  }

  String _dateLabel(String raw) {
    final at = DateTime.tryParse(raw)?.toLocal();
    if (at == null) return '更早';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)}';
  }

  Future<void> _playLocal(LibraryRecord record) async {
    final path = record.episodeId;
    if (!File(path).existsSync()) {
      _snack(AppStrings.fileMissing);
      return;
    }
    // Downloads live in one folder per series; pass its siblings so the
    // player can switch episodes with the wheel.
    final siblings = LocalMedia.collectVideos([File(path).parent.path]);
    // Keep the folder's natural order; the clicked file is the start point.
    final paths = siblings.length > 1 ? siblings : [path];
    AppScope.of(context).localPlaylist.setPlaylist(
          paths,
          title: record.title,
          current: path,
        );
    await Navigator.of(context).push(
      instantRoute(
        (_) => OpaquePage(
          child: PlayerScreen(
            plan: LocalMedia.buildPlan(path),
            title: record.title,
            itemId: paths.length == 1
                ? 'local:$path'
                : 'local:${File(path).parent.path}',
            localFiles: paths,
            episodeId: path,
            windowToggle: true,
          ),
        ),
      ),
    );
  }

  Widget _downloadsBody(BuildContext context) {
    final manager = AppScope.of(context).downloads;
    final sourceId = AppScope.controllerOf(context).sourceApi?.sourceId ?? '';
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final groups = _downloadGroups(
          manager.records
              .where((record) =>
                  sourceId.isEmpty ||
                  record.seriesKey.startsWith('$sourceId:'))
              .toList(),
        );
        if (groups.isEmpty) {
          return const StatePanel(
            icon: Icons.download_outlined,
            title: AppStrings.emptyTitle,
            body: AppStrings.downloadsEmptyBody,
          );
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: groups.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.x2),
          itemBuilder: (context, index) {
            final group = groups[index];
            return _DownloadSeriesCard(
              group: group,
              subtitle: _downloadSubtitle(group, manager),
              progress: _downloadProgress(group, manager),
              onTap: () => _showDownloadGroup(group),
            );
          },
        );
      },
    );
  }

  double? _downloadProgress(_DownloadGroup group, DownloadManager manager) {
    var sum = 0.0;
    var active = 0;
    for (final episode in group.episodes) {
      if (episode.state == 'done' || episode.state == 'error') continue;
      active++;
      sum += manager.progressOf(episode.assetId) ?? 0;
    }
    if (active == 0) return null;
    return (sum / active).clamp(0.0, 1.0);
  }

  String _downloadSubtitle(_DownloadGroup group, DownloadManager manager) {
    var done = 0;
    var active = 0;
    var failed = 0;
    for (final episode in group.episodes) {
      if (episode.state == 'done') {
        done++;
      } else if (episode.state == 'error') {
        failed++;
      } else {
        active++;
      }
    }
    final progress = _downloadProgress(group, manager);
    final percent = progress == null ? '' : ' ${(progress * 100).round()}%';
    final parts = <String>[
      if (active > 0) '下载中 $active 集$percent',
      if (done > 0) '已下载 $done 集',
      if (failed > 0) '失败 $failed 集',
    ];
    final size = done > 0 ? ' · ${group.sizeLabel}' : '';
    return parts.isEmpty ? '暂无进度' : '${parts.join(' · ')}$size';
  }

  List<_DownloadGroup> _downloadGroups(List<DownloadRecord> records) {
    final map = <String, _DownloadGroup>{};
    for (final record in records) {
      // In-progress and failed episodes stay visible: the download page is
      // where the user checks on them.
      final group = map.putIfAbsent(
        record.seriesKey,
        () => _DownloadGroup(
          seriesKey: record.seriesKey,
          title: record.title,
          cover: record.cover,
        ),
      );
      group.episodes.add(record);
      if (record.createdAt.compareTo(group.latest) > 0) {
        group.latest = record.createdAt;
      }
    }
    final groups = map.values.toList();
    for (final group in groups) {
      group.episodes.sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
    }
    groups.sort((a, b) => b.latest.compareTo(a.latest));
    return groups;
  }

  void _showDownloadGroup(_DownloadGroup group) {
    final tokens = AppTokens.of(context);
    final manager = AppScope.of(context).downloads;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.colors.surface,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.62,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  AppSpacing.x3,
                  AppSpacing.x2,
                  AppSpacing.x2,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      height: 54,
                      child: CoverImage(
                        url: group.cover,
                        seed: group.title,
                        radius: AppRadius.sm,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.title.isEmpty ? '未命名剧集' : group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: AppFontSize.bodyLg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _downloadSubtitle(
                              group,
                              AppScope.of(context).downloads,
                            ),
                            style: TextStyle(
                              fontSize: AppFontSize.xxs,
                              color: tokens.colors.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: Icon(Icons.close, color: tokens.colors.text2),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: tokens.colors.border),
              Expanded(
                child: ListenableBuilder(
                  listenable: manager,
                  builder: (context, _) => ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x1,
                  ),
                  itemCount: group.episodes.length,
                  itemBuilder: (context, index) {
                    final record = group.episodes[index];
                    final done = record.state == 'done';
                    final failed = record.state == 'error';
                    final paused = record.state == 'paused';
                    final retryable = failed || paused;
                    final percent = (manager.progressOf(record.assetId) ?? 0);
                    return InkWell(
                      onTap: done
                          ? () {
                              Navigator.of(sheetContext).pop();
                              _playDownloaded(record);
                            }
                          : retryable
                              ? () => _retryDownload(record)
                              : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Icon(
                              done
                                  ? Icons.play_circle_outline
                                  : failed
                                      ? Icons.error_outline
                                      : Icons.downloading,
                              size: 18,
                              color: done
                                  ? tokens.colors.accent
                                  : failed
                                      ? tokens.colors.danger
                                      : tokens.colors.text3,
                            ),
                            const SizedBox(width: AppSpacing.x3),
                            Expanded(
                              child: Text(
                                record.episodeLabel.isEmpty
                                    ? '第${record.episodeIndex}集'
                                    : record.episodeLabel,
                                style:
                                    const TextStyle(fontSize: AppFontSize.body),
                              ),
                            ),
                            Text(
                              done
                                  ? _sizeLabel(record.bytes)
                                  : failed
                                      ? '失败 · 重试'
                                      : paused
                                          ? '已暂停 · 继续'
                                          : record.state == 'queued'
                                              ? '排队中'
                                              : '下载中 ${(percent * 100).round()}%',
                              style: TextStyle(
                                fontSize: AppFontSize.xxs,
                                color: failed
                                    ? tokens.colors.danger
                                    : paused
                                        ? tokens.colors.accent
                                        : tokens.colors.text3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDownloadsFolder() async {
    final settings = AppScope.controllerOf(context).settings;
    final path = settings.downloadDirectory.trim().isEmpty
        ? defaultDownloadDirectory()
        : settings.downloadDirectory;
    await AppScope.of(context).fileAssociation.openFolder(path);
  }

  Future<void> _clearDownloads() async {
    final manager = AppScope.of(context).downloads;
    final count = manager.records.length;
    if (count == 0) {
      _snack('没有可清空的下载');
      return;
    }
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('清空下载'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将清空 $count 条下载记录。'),
              const SizedBox(height: AppSpacing.x2),
              CheckboxListTile(
                value: deleteFiles,
                onChanged: (value) =>
                    setDialogState(() => deleteFiles = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时删除本地文件'),
                subtitle: const Text('不勾选时只清空记录，视频文件保留在下载目录'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await manager.clearAll(deleteFiles: deleteFiles);
    if (!mounted) return;
    _snack(deleteFiles ? '已清空记录并删除本地文件' : '已清空记录，本地文件保留');
  }

  Future<void> _resume(LibraryRecord record) async {
    final api = AppScope.controllerOf(context).sourceApi;
    if (record.sourceId == 'local' ||
        (record.episodeId.isNotEmpty &&
            File(record.episodeId).existsSync() &&
            api == null)) {
      await _playLocal(record);
      return;
    }
    if (api == null || record.sourceId != api.sourceId) {
      _snack(AppStrings.switchSourceFirst);
      return;
    }
    try {
      final exit = await resumeLibraryRecord(context, api, record);
      if (exit != null && mounted) {
        await openDetail(
          context,
          api,
          exit.item,
          poster: exit.poster,
        );
      }
    } on Object catch (error) {
      _snack(describeGatewayError(error));
    }
    if (mounted) _reload();
  }

  Future<void> _deleteHistoryRecord(LibraryRecord record) async {
    await AppScope.of(context).library.removeHistory({record.seriesKey});
    if (!mounted) return;
    _reload();
  }

  void _retryDownload(DownloadRecord record) {
    final api = AppScope.controllerOf(context).sourceApi;
    final sourceId = record.seriesKey.split(':').first;
    if (api == null || api.sourceId != sourceId) {
      _snack(AppStrings.switchSourceFirst);
      return;
    }
    AppScope.of(context).downloads.retry(api, record);
  }

  Future<void> _playDownloaded(DownloadRecord download) async {
    final manager = AppScope.of(context).downloads;
    final path = manager.localPathFor(download.seriesKey, download.episodeId);
    if (path == null) {
      _snack(AppStrings.fileMissing);
      return;
    }
    final parts = download.seriesKey.split(':');
    final sourceId = parts.isNotEmpty ? parts.first : '';
    final itemId = parts.length > 1 ? parts.sublist(1).join(':') : '';
    final api = AppScope.controllerOf(context).sourceApi;
    var episodes = const <Episode>[];
    var withApi = false;
    if (api != null && api.sourceId == sourceId && itemId.isNotEmpty) {
      try {
        episodes = (await api.episodes(itemId)).episodes;
        withApi = episodes.isNotEmpty;
      } on Object {
        // Offline: fall back to the downloaded files only.
      }
    }
    if (!mounted) return;
    final locals = manager.records
        .where((record) =>
            record.seriesKey == download.seriesKey &&
            record.state == 'done' &&
            record.path.isNotEmpty &&
            File(record.path).existsSync())
        .toList()
      ..sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
    if (locals.isNotEmpty) {
      AppScope.of(context).localPlaylist.setPlaylist(
            locals.map((r) => r.path).toList(),
            title: download.title,
            current: path,
          );
    }
    await Navigator.of(context).push(
      instantRoute(
        (_) => OpaquePage(
          child: PlayerScreen(
            plan: LocalMedia.buildPlan(path),
            title: download.title,
            api: withApi ? api : null,
            itemId: withApi ? itemId : '',
            episodes: withApi ? episodes : const [],
            episodeId: withApi ? download.episodeId : path,
            cover: download.cover,
            localFiles:
                withApi ? const [] : locals.map((r) => r.path).toList(),
            windowToggle: true,
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ReservationRow extends StatelessWidget {
  const _ReservationRow({
    required this.item,
    required this.online,
    required this.onOpen,
    required this.onCancel,
    this.selecting = false,
    this.selected = false,
  });

  final Item item;
  final bool online;
  final VoidCallback? onOpen;
  final VoidCallback? onCancel;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final extra = item.extra;
    final category = str(extra['category']);
    final count = intOr(extra['episode_count']);
    final publish = extra['publish_at'];
    var date = '';
    if (publish is num && publish > 0) {
      final at = DateTime.fromMillisecondsSinceEpoch(publish.toInt() * 1000);
      String two(int value) => value.toString().padLeft(2, '0');
      date = '预计 ${two(at.month)}-${two(at.day)} 上线';
    }
    final meta = [
      if (category.isNotEmpty) category,
      if (count > 0) '共$count集',
      if (!online && date.isNotEmpty) date,
    ].join(' · ');
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x1,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: tokens.colors.border.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
          children: [
            if (selecting) ...[
              _SelectDot(selected: selected, onTap: onOpen ?? () {}),
              const SizedBox(width: AppSpacing.x2),
            ],
            SizedBox(
              width: 52,
              height: 70,
              child: CoverImage(
                url: item.cover,
                seed: item.title,
                radius: AppRadius.sm,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSize.bodyLg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.x1),
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: AppFontSize.xs,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.x1),
                  AppBadge(
                    label: online ? '已上线' : '待上线',
                    compact: true,
                  ),
                ],
              ),
            ),
            if (!selecting)
              TextButton(
                onPressed: onCancel,
                child: Text(online ? '移除' : '取消预约'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FollowRow extends StatelessWidget {
  const _FollowRow({
    required this.item,
    required this.onTap,
    this.selecting = false,
    this.selected = false,
    this.onUnfollow,
  });

  final Item item;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onUnfollow;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final extra = item.extra;
    final latest = intOr(extra['vid_index']);
    final count = intOr(extra['episode_count']);
    final upToDate = extra['up_to_date'] == true;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x1,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: tokens.colors.border.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
          children: [
            if (selecting) ...[
              _SelectDot(selected: selected, onTap: onTap ?? () {}),
              const SizedBox(width: AppSpacing.x2),
            ],
            SizedBox(
              width: 52,
              height: 70,
              child: CoverImage(
                url: item.cover,
                seed: item.title,
                radius: AppRadius.sm,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSize.bodyLg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Row(
                    children: [
                      Text(
                        latest > 0
                            ? '最新第$latest集 · 共$count集'
                            : '共$count集',
                        style: TextStyle(
                          fontSize: AppFontSize.xs,
                          color: tokens.colors.text3,
                        ),
                      ),
                      if (!upToDate) ...[
                        const SizedBox(width: AppSpacing.x2),
                        const AppBadge(label: '有更新', compact: true),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (!selecting && onUnfollow != null)
              IconButton(
                tooltip: '取消追更',
                onPressed: onUnfollow,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                icon: Icon(
                  Icons.bookmark_remove_outlined,
                  size: 18,
                  color: tokens.colors.text3,
                ),
              ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: tokens.colors.text3,
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryHero extends StatelessWidget {
  const _HistoryHero({
    required this.record,
    required this.onResume,
    required this.onOpen,
    this.showCover = true,
  });

  final LibraryRecord record;
  final VoidCallback onResume;
  final VoidCallback onOpen;
  final bool showCover;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final count = record.episodeCount;
    final watched = record.episodeIndex;
    final parts = [
      if (watched > 0 && count > 0)
        '已看 $watched/$count 集'
      else if (watched > 0)
        '第$watched集',
      _timeLabel(record.updatedAt),
      if (watched > 0 && count > 0 && watched >= count) '已看完',
    ];
    final meta = parts.join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x4),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.x3),
        decoration: BoxDecoration(
          color: tokens.colors.surface2.withValues(alpha: 0.50),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: tokens.colors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showCover) ...[
              GestureDetector(
                onTap: onOpen,
                child: SizedBox(
                  width: 96,
                  height: 128,
                  child: CoverImage(
                    url: record.cover,
                    seed: record.title,
                    radius: AppRadius.sm,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x4),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '继续观看',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      fontWeight: FontWeight.w700,
                      color: tokens.colors.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    record.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.text3,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(height: AppSpacing.x2),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: _seriesProgress(record),
                        minHeight: 3,
                        backgroundColor:
                            tokens.colors.border.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.x3),
                  FilledButton.icon(
                    onPressed: onResume,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('继续观看'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectDot extends StatelessWidget {
  const _SelectDot({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: selected
              ? tokens.colors.accent
              : Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white70),
        ),
        child: Icon(
          selected ? Icons.check : Icons.add,
          size: 14,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.showProgress,
    required this.trailing,
    this.showCover = true,
    this.onTap,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final LibraryRecord record;
  final bool showProgress;
  final Widget trailing;
  final bool showCover;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final count = record.episodeCount;
    final watched = record.episodeIndex;
    final meta = [
      if (watched > 0 && count > 0)
        '已看 $watched/$count 集'
      else if (watched > 0)
        '第$watched集'
      else
        _timeLabel(record.updatedAt),
      if (showProgress && watched > 0 && count > 0 && watched >= count) '已看完',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x1,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: tokens.colors.border.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.x1),
              child: Checkbox(
                value: selected,
                onChanged: (_) => onToggleSelect?.call(),
              ),
            ),
          if (showCover) ...[
            SizedBox(
              width: 44,
              height: 60,
              child: CoverImage(
                url: record.cover,
                seed: record.title,
                radius: AppRadius.sm,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppFontSize.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: AppFontSize.xxs,
                    color: tokens.colors.text3,
                  ),
                ),
                if (showProgress && count > 0 && watched > 0) ...[
                  const SizedBox(height: AppSpacing.x1),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: _seriesProgress(record),
                      minHeight: 3,
                      backgroundColor:
                          tokens.colors.border.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing,
          ],
        ),
      ),
    );
  }
}

class _DownloadGroup {
  _DownloadGroup({
    required this.seriesKey,
    required this.title,
    required this.cover,
  });

  final String seriesKey;
  final String title;
  final String cover;
  final List<DownloadRecord> episodes = [];
  String latest = '';

  int get bytes => episodes.fold(0, (sum, record) => sum + record.bytes);

  String get sizeLabel {
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }
}

class _DownloadSeriesCard extends StatelessWidget {
  const _DownloadSeriesCard({
    required this.group,
    required this.subtitle,
    required this.progress,
    required this.onTap,
  });

  final _DownloadGroup group;
  final String subtitle;
  final double? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.x2),
        decoration: BoxDecoration(
          color: tokens.colors.surface2.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: tokens.colors.border.withValues(alpha: 0.7),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              height: 70,
              child: CoverImage(
                url: group.cover,
                seed: group.title,
                radius: AppRadius.sm,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title.isEmpty ? '未命名剧集' : group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppFontSize.bodyLg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppFontSize.xxs,
                      color: tokens.colors.text3,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: AppSpacing.x1),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: tokens.colors.text3),
          ],
        ),
      ),
    );
  }
}

String _sizeLabel(int bytes) {
  if (bytes <= 0) return '';
  final mb = bytes / (1024 * 1024);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.toStringAsFixed(1)} MB';
}

/// History bars describe the series, not one episode: how far through the
/// episode list the viewer is.
double _seriesProgress(LibraryRecord record) {
  final count = record.episodeCount;
  if (count <= 0 || record.episodeIndex <= 0) return 0;
  return (record.episodeIndex / count).clamp(0.0, 1.0);
}

/// A series counts as finished when its last episode is the one reached, or
/// when a single-file video sat at the end. Older records never wrote the
/// flag, so the position is a second source of truth.
bool _recordFinished(LibraryRecord record) {
  if (record.finished) return true;
  final count = record.episodeCount;
  final index = record.episodeIndex;
  if (count <= 1) {
    return record.durationSec > 0 &&
        record.positionSec >= record.durationSec - 2;
  }
  return index > 0 && index >= count;
}
