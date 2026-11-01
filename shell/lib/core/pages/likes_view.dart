import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';
import 'common.dart';
import 'loading.dart';
import 'login_sheet.dart';

/// 点赞 grouped by drama: one card per series with its liked episodes as
/// small chips, instead of one card per episode. Supports per-series delete,
/// multi-select and a 同剧 filter.
class LikesView extends StatefulWidget {
  const LikesView({
    super.key,
    required this.api,
    required this.onOpenDetail,
    required this.onPlayEpisode,
    this.onChanged,
    this.onSelectingChanged,
  });

  final SourceApi api;
  final ValueChanged<Item> onOpenDetail;
  final ValueChanged<Item> onPlayEpisode;
  final VoidCallback? onChanged;
  final ValueChanged<bool>? onSelectingChanged;

  @override
  State<LikesView> createState() => LikesViewState();
}

class LikesViewState extends State<LikesView> {
  final List<Item> _items = [];
  final ScrollController _scroll = ScrollController();
  String _next = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _selecting = false;
  Object? _error;
  final Set<String> _selectedSeries = {};
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeMore);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeMore() {
    if (!_scroll.hasClients || _loadingMore || _next.isEmpty) return;
    if (_scroll.position.extentAfter < 600) _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loadingMore || _next.isEmpty)) return;
    final epoch = reset ? ++_epoch : _epoch;
    setState(() {
      if (reset) {
        _items.clear();
        _next = '';
        _error = null;
        _loading = true;
        _selecting = false;
        _selectedSeries.clear();
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.api.likes(
        cursor: reset ? '' : _next,
        limit: 50,
      );
      if (!mounted || epoch != _epoch) return;
      final seen = _items.map(_likeKey).toSet();
      setState(() {
        _items.addAll(
          page.items.where((item) => seen.add(_likeKey(item))),
        );
        _next = page.next;
        _loading = false;
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = error;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// Toggled from the page's tab row, so the grid does not spend a line on
  /// its own toolbar.
  void toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selectedSeries.clear();
    });
    widget.onSelectingChanged?.call(_selecting);
  }

  // One like row is one episode; the series id groups them.
  String _likeKey(Item item) => '${item.id}:${str(item.extra['vid'])}';

  List<_LikeGroup> get _groups {
    final map = <String, _LikeGroup>{};
    for (final item in _items) {
      final group = map.putIfAbsent(item.id, () => _LikeGroup(item: item));
      group.episodes.add(item);
    }
    final groups = map.values.toList(growable: false);
    for (final group in groups) {
      group.episodes.sort((a, b) =>
          intOr(a.extra['vid_index']).compareTo(intOr(b.extra['vid_index'])));
    }
    groups.sort(
      (a, b) => b.episodes.length.compareTo(a.episodes.length),
    );
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView(skeleton: SkeletonList());
    final error = _error;
    if (error != null && _items.isEmpty) {
      if (error is SpException && error.code == SpErrorCode.unauthorized) {
        return StatePanel(
          icon: Icons.thumb_up_outlined,
          title: '点赞需要登录',
          body: '登录账号后，这里显示你点赞过的剧集。',
          action: FilledButton(
            onPressed: () async {
              if (!await showLoginSheet(context, api: widget.api)) return;
              if (mounted) _load(reset: true);
            },
            child: const Text(AppStrings.login),
          ),
        );
      }
      return StatePanel(
        icon: Icons.error_outline,
        title: AppStrings.errorTitle,
        body: describeGatewayError(error),
        action: OutlinedButton(
          onPressed: () => _load(reset: true),
          child: const Text(AppStrings.retry),
        ),
      );
    }
    final groups = _groups;
    if (groups.isEmpty) {
      return const StatePanel(
        icon: Icons.thumb_up_outlined,
        title: '还没有点赞记录',
      );
    }
    final tokens = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_selecting)
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.x2,
              bottom: AppSpacing.x3,
            ),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    final all = _groups.map((g) => g.item.id).toSet();
                    if (_selectedSeries.length == all.length) {
                      _selectedSeries.clear();
                    } else {
                      _selectedSeries
                        ..clear()
                        ..addAll(all);
                    }
                  }),
                  child: Text(
                    _selectedSeries.length == _groups.length ? '取消全选' : '全选',
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _selectedSeries.isEmpty
                      ? null
                      : () => _deleteSeries(_selectedSeries.toSet()),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text('删除 ${_selectedSeries.length}'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.colors.danger,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _maybeMore();
              return false;
            },
            child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.only(
                top: AppSpacing.x2,
                bottom: AppSpacing.x4,
              ),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisExtent: 252,
                mainAxisSpacing: AppSpacing.x4,
                crossAxisSpacing: AppSpacing.x4,
              ),
              itemCount: groups.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= groups.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                final group = groups[index];
                return _LikeSeriesCard(
                  group: group,
                  selecting: _selecting,
                  selected: _selectedSeries.contains(group.item.id),
                  onSelect: () => setState(() {
                    if (!_selectedSeries.remove(group.item.id)) {
                      _selectedSeries.add(group.item.id);
                    }
                  }),
                  onOpen: () => widget.onOpenDetail(group.item),
                  onPlayEpisode: widget.onPlayEpisode,
                  onDelete: () => _deleteSeries({group.item.id}),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _deleteSeries(Set<String> seriesIds) async {
    final groups = _groups.where((g) => seriesIds.contains(g.item.id));
    var failed = false;
    for (final group in groups) {
      for (final episode in group.episodes) {
        final vid = str(episode.extra['vid']);
        try {
          await widget.api.setLike(group.item.id, false, episodeId: vid);
        } on Object catch (error) {
          if (error is SpException &&
              error.code == SpErrorCode.unauthorized &&
              mounted) {
            if (!await showLoginSheet(context, api: widget.api)) {
              failed = true;
              break;
            }
            try {
              await widget.api.setLike(group.item.id, false, episodeId: vid);
              continue;
            } on Object {
              failed = true;
              break;
            }
          }
          failed = true;
          break;
        }
      }
      if (failed) break;
    }
    if (!mounted) return;
    setState(() {
      _items.removeWhere((item) => seriesIds.contains(item.id));
      _selectedSeries.removeAll(seriesIds);
      if (_selectedSeries.isEmpty) _selecting = false;
    });
    widget.onChanged?.call();
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('部分点赞未能取消，请稍后重试')),
      );
    }
  }
}

class _LikeGroup {
  _LikeGroup({required this.item});

  final Item item;
  final List<Item> episodes = [];
}

class _LikeSeriesCard extends StatelessWidget {
  const _LikeSeriesCard({
    required this.group,
    required this.selecting,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onPlayEpisode,
    required this.onDelete,
  });

  final _LikeGroup group;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Item> onPlayEpisode;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final item = group.item;
    return GestureDetector(
      onTap: selecting ? onSelect : onOpen,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.colors.surface2.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? tokens.colors.accent : tokens.colors.border,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 136,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverImage(
                      url: item.cover,
                      seed: item.title,
                      fit: BoxFit.cover,
                      decodeWidth: 400,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.78),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: AppSpacing.x2,
                      right: AppSpacing.x2,
                      bottom: AppSpacing.x2,
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppFontSize.bodyLg,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          shadows: [
                            Shadow(color: Color(0x99000000), blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: AppSpacing.x1,
                      right: AppSpacing.x1,
                      child: selecting
                          ? GestureDetector(
                              onTap: onSelect,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? tokens.colors.accent
                                      : Colors.black.withValues(alpha: 0.45),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white70),
                                ),
                                child: Icon(
                                  selected ? Icons.check : Icons.add,
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : AppBadge(
                              label: '已赞 ${group.episodes.length} 集',
                              onImage: true,
                              compact: true,
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x2,
                  AppSpacing.x2,
                  AppSpacing.x1,
                  AppSpacing.x2,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          intOr(item.extra['episode_count']) > 0
                              ? '共${intOr(item.extra['episode_count'])}集'
                              : '点赞记录',
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                          ),
                        ),
                        const Spacer(),
                        if (!selecting)
                          IconButton(
                            tooltip: '取消点赞',
                            onPressed: onDelete,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 26,
                              height: 26,
                            ),
                            icon: Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: tokens.colors.text3,
                            ),
                          ),
                      ],
                    ),
                    Wrap(
                      spacing: AppSpacing.x1,
                      runSpacing: AppSpacing.x1,
                      children: [
                        for (final episode in group.episodes.take(5))
                          _EpisodeChip(
                            label: _episodeLabel(episode),
                            onTap: selecting
                                ? null
                                : () => onPlayEpisode(episode),
                          ),
                        if (group.episodes.length > 5)
                          Text(
                            '+${group.episodes.length - 5}',
                            style: TextStyle(
                              fontSize: AppFontSize.xxs,
                              color: tokens.colors.text3,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _episodeLabel(Item episode) {
    final index = intOr(episode.extra['vid_index']);
    return index > 0 ? '第$index集' : '已赞';
  }
}

class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x2,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: tokens.colors.surface2.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: tokens.colors.border.withValues(alpha: 0.55),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.xxs,
            color: tokens.colors.text2,
          ),
        ),
      ),
    );
  }
}
