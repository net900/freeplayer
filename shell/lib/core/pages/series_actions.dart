import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../gateway/source_api.dart';
import '../library/local_library.dart';
import '../sp/models.dart';
import '../theme/tokens.dart';
import 'comment_sheet.dart';
import 'common.dart';
import 'login_sheet.dart';

/// One round button of the vertical rail (feed and player share it).
class RailAction extends StatelessWidget {
  const RailAction({
    super.key,
    required this.icon,
    required this.color,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Color(0x40000000),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: AppFontSize.xxs,
              color: Colors.white,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
            ),
          ),
        ],
      ),
    );
  }
}

/// 点赞 / 收藏 / 剧评 for one drama. The feed and the full player both use
/// this: same state, same writes, same sheet — one implementation.
class SeriesActionRail extends StatefulWidget {
  const SeriesActionRail({
    super.key,
    required this.api,
    required this.item,
    this.episodeId = '',
    this.stats,
    this.spacing = AppSpacing.x4,
    this.kind = 'comment',
    this.title = '评论',
    this.onLikeChanged,
  });

  final SourceApi api;
  final Item item;
  final String episodeId;
  final ItemStats? stats;
  final double spacing;

  /// 剧评 is series-level; 评论 is per-episode. They share the endpoint and
  /// differ by group id, so the caller picks both the kind and the label.
  final String kind;
  final String title;

  /// Lets the owner (the player) remember a per-episode like across episode
  /// switches, where the episode DTO is still the pre-write snapshot.
  final void Function(bool liked, int likeCount)? onLikeChanged;

  @override
  State<SeriesActionRail> createState() => _SeriesActionRailState();
}

class _SeriesActionRailState extends State<SeriesActionRail> {
  late bool _liked;
  late int _likeCount;
  late int _commentCount;
  bool _favorite = false;
  bool _favoriteLoaded = false;

  String get _seriesKey => '${widget.api.sourceId}:${widget.item.id}';

  @override
  void initState() {
    super.initState();
    final extra = widget.item.extra;
    _liked = widget.stats?.liked ?? extra['liked'] == true;
    _likeCount = widget.stats?.likeCount ?? _extraInt(extra['like_count']);
    _commentCount =
        widget.stats?.commentCount ?? _extraInt(extra['comment_count']);
  }

  static int _extraInt(Object? raw) => raw is num ? raw.toInt() : 0;

  @override
  void didUpdateWidget(SeriesActionRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeId == widget.episodeId &&
        identical(oldWidget.stats, widget.stats)) {
      return;
    }
    final extra = widget.item.extra;
    _liked = widget.stats?.liked ?? extra['liked'] == true;
    _likeCount = widget.stats?.likeCount ?? _extraInt(extra['like_count']);
    _commentCount =
        widget.stats?.commentCount ?? _extraInt(extra['comment_count']);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_favoriteLoaded) return;
    _favoriteLoaded = true;
    _loadFavorite();
  }

  Future<void> _loadFavorite() async {
    try {
      final favorite =
          await AppScope.of(context).library.isFavorite(_seriesKey);
      if (mounted) setState(() => _favorite = favorite);
    } on Object {
      // Without local state the icon simply stays white.
    }
  }

  /// Runs the write, and retries once after the login sheet if the account is
  /// missing — the same behaviour as the detail page.
  Future<void> _authAware(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (error is! SpException || error.code != SpErrorCode.unauthorized) {
        rethrow;
      }
      if (!mounted) return;
      if (!await showLoginSheet(context, api: widget.api)) rethrow;
      if (!mounted) return;
      await action();
    }
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
    });
    widget.onLikeChanged?.call(_liked, _likeCount);
    try {
      await _authAware(
        () => widget.api.setLike(
          widget.item.id,
          next,
          episodeId: widget.episodeId,
        ),
      );
    } on Object {
      // The upstream series-like write is best-effort; the local state keeps
      // the tap responsive.
    }
  }

  Future<void> _toggleFavorite() async {
    final item = widget.item;
    final next = !_favorite;
    setState(() => _favorite = next);
    try {
      await _authAware(() => widget.api.setFavorite(item.id, next));
    } on Object {
      // Local favorites still work offline; the shelf write is best-effort.
    }
    try {
      await AppScope.of(context).library.toggleFavorite(
            LibraryRecord(
              seriesKey: _seriesKey,
              title: item.title,
              cover: item.cover,
              sourceId: widget.api.sourceId,
              itemId: item.id,
              updatedAt: DateTime.now().toIso8601String(),
            ),
          );
    } on Object {
      // Storage failure leaves the icon as it was.
    }
  }

  Future<void> _openComments() async {
    final changed = await showCommentSheet(
      context,
      api: widget.api,
      itemId: widget.item.id,
      episodeId: widget.episodeId,
      kind: widget.kind,
      title: widget.title,
    );
    if (changed && mounted) setState(() => _commentCount += 1);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RailAction(
          icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: _liked ? const Color(0xFFFF5A6E) : Colors.white,
          value: formatCount(_likeCount),
          onTap: _toggleLike,
        ),
        SizedBox(height: widget.spacing),
        RailAction(
          icon: _favorite
              ? Icons.bookmark_added_rounded
              : Icons.bookmark_border_rounded,
          color: _favorite ? const Color(0xFFFFC24B) : Colors.white,
          value: formatCount(
            widget.stats?.followCount ?? _extraInt(widget.item.extra['follow_count']),
          ),
          onTap: _toggleFavorite,
        ),
        SizedBox(height: widget.spacing),
        RailAction(
          icon: Icons.mode_comment_rounded,
          color: Colors.white,
          value: formatCount(_commentCount),
          onTap: _openComments,
        ),
      ],
    );
  }
}
