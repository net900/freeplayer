import 'package:flutter/material.dart';

import '../../l10n/strings.dart';

import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../sp/emoji.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'login_sheet.dart';

/// 评论 / 短评 / 弹幕 panel. One upstream endpoint serves all three; the
/// gateway picks comment_type from `kind`.
Future<bool> showCommentSheet(
  BuildContext context, {
  required SourceApi api,
  required String itemId,
  String episodeId = '',
  String kind = 'comment',
  String title = '评论',
  String? emptyText,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.of(context).colors.surface,
    builder: (sheetContext) => CommentSheet(
      api: api,
      itemId: itemId,
      episodeId: episodeId,
      kind: kind,
      title: title,
      emptyText: emptyText,
    ),
  );
  return result ?? false;
}

class CommentSheet extends StatefulWidget {
  const CommentSheet({
    super.key,
    required this.api,
    required this.itemId,
    this.episodeId = '',
    this.kind = 'comment',
    this.title = '评论',
    this.emptyText,
  });

  final SourceApi api;
  final String itemId;
  final String episodeId;
  final String kind;
  final String title;
  final String? emptyText;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Comment> _items = [];
  String _next = '';
  bool _loading = true;
  bool _sending = false;
  bool _loadingMore = false;
  bool _changed = false;
  bool _needsLogin = false;
  String? _error;
  String _replyTo = '';
  String _replyName = '';

  String get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loadingMore || _next.isEmpty)) return;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.api.comments(
        itemId: widget.itemId,
        episodeId: widget.episodeId,
        kind: _kind,
        cursor: reset ? '' : _next,
        limit: 20,
      );
      if (!mounted) return;
      final seen = _items.map((c) => c.id).toSet();
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items.where((c) => !seen.contains(c.id)));
        _next = page.hasMore ? page.next : '';
        _loading = false;
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeGatewayError(error);
        _needsLogin =
            error is SpException && error.code == SpErrorCode.unauthorized;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (_replyTo.isNotEmpty) {
        await widget.api.replyComment(
          itemId: widget.itemId,
          commentId: _replyTo,
          episodeId: widget.episodeId,
          kind: _kind,
          text: text,
        );
      } else {
        await widget.api.addComment(
          itemId: widget.itemId,
          episodeId: widget.episodeId,
          kind: _kind,
          text: text,
        );
      }
      if (!mounted) return;
      _input.clear();
      setState(() {
        _replyTo = '';
        _replyName = '';
        _sending = false;
        _changed = true;
      });
      await _load(reset: true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = describeGatewayError(error);
        _needsLogin =
            error is SpException && error.code == SpErrorCode.unauthorized;
      });
    }
  }

  Future<void> _login() async {
    final ok = await showLoginSheet(context, api: widget.api);
    if (!mounted || !ok) return;
    await _load(reset: true);
  }

  Future<void> _toggleLike(Comment comment) async {
    final liked = !comment.liked;
    final index = _items.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    setState(() {
      _items[index] = comment.copyWith(
        liked: liked,
        likeCount: comment.likeCount + (liked ? 1 : -1),
      );
      _changed = true;
    });
    try {
      await widget.api.likeComment(
        comment.id,
        kind: _kind,
        liked: liked,
        itemId: widget.itemId,
        episodeId: widget.episodeId,
      );
    } on Object {
      if (!mounted) return;
      // The list may have been reloaded by a send/delete in the meantime;
      // reverting by index could touch the wrong row.
      final current = _items.indexWhere((c) => c.id == comment.id);
      if (current < 0) return;
      setState(() {
        _items[current] = comment;
      });
    }
  }

  Future<void> _openReplies(Comment comment) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTokens.of(context).colors.surface,
      builder: (_) => _ReplySheet(
        api: widget.api,
        itemId: widget.itemId,
        episodeId: widget.episodeId,
        kind: _kind,
        comment: comment,
      ),
    );
  }

  Future<void> _delete(Comment comment) async {
    try {
      await widget.api.deleteComment(comment.id, kind: _kind);
      if (!mounted) return;
      setState(() {
        _items.removeWhere((c) => c.id == comment.id);
        _changed = true;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = describeGatewayError(error));
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < 300) _load();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final height = MediaQuery.of(context).size.height * 0.68;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  AppSpacing.x3,
                  AppSpacing.x2,
                  AppSpacing.x1,
                ),
                child: Row(
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: tokens.colors.text,
                        fontSize: AppFontSize.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(_changed),
                      icon: Icon(Icons.close, color: tokens.colors.text2),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: tokens.colors.accent,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(child: _list(tokens)),
              _composer(tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(AppTokens tokens) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _needsLogin
                  ? '登录后可查看评论和弹幕'
                  : (_error == null
                      ? (widget.emptyText ?? '还没有内容')
                      : '加载失败'),
              style: TextStyle(color: tokens.colors.text3),
            ),
            if (_needsLogin) ...[
              const SizedBox(height: AppSpacing.x3),
              FilledButton(
                onPressed: _login,
                child: const Text('登录'),
              ),
            ] else if (_error != null) ...[
              // A failed first load used to dead-end here.
              const SizedBox(height: AppSpacing.x3),
              FilledButton(
                onPressed: () => _load(reset: true),
                child: const Text(AppStrings.retry),
              ),
            ],
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: tokens.colors.border,
        ),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.x3),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final comment = _items[index];
          return _CommentRow(
            comment: comment,
            kind: _kind,
            onLike: () => _toggleLike(comment),
            onReply: () {
              setState(() {
                _replyTo = comment.id;
                _replyName = comment.userName;
              });
            },
            onDelete: comment.isMine ? () => _delete(comment) : null,
            onReplies:
                comment.replyCount > 0 ? () => _openReplies(comment) : null,
          );
        },
      ),
    );
  }

  Widget _composer(AppTokens tokens) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x3,
        AppSpacing.x3,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: tokens.colors.border),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo.isNotEmpty)
            Row(
              children: [
                Text(
                  '回复 ${_replyName.isEmpty ? _replyTo : _replyName}',
                  style: TextStyle(fontSize: 11, color: tokens.colors.accent),
                ),
                const SizedBox(width: AppSpacing.x2),
                InkWell(
                  onTap: () => setState(() {
                    _replyTo = '';
                    _replyName = '';
                  }),
                  child: Icon(Icons.close, size: 14, color: tokens.colors.text3),
                ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  style: TextStyle(color: tokens.colors.text),
                  maxLength: 300,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: _kind == 'danmaku' ? '发一条弹幕…' : '说点什么…',
                    hintStyle: TextStyle(color: tokens.colors.text3),
                    filled: true,
                    fillColor: tokens.colors.surface2,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3,
                      vertical: AppSpacing.x2,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.kind,
    required this.onLike,
    required this.onReply,
    this.onDelete,
    this.onReplies,
  });

  final Comment comment;
  final String kind;
  final VoidCallback onLike;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;
  final VoidCallback? onReplies;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: tokens.colors.surface2,
            backgroundImage: comment.avatar.isEmpty
                ? null
                : NetworkImage(comment.avatar),
            child: comment.avatar.isEmpty
                ? Icon(Icons.person, size: 16, color: tokens.colors.text3)
                : null,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.userName.isEmpty ? '匿名' : comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.colors.text2,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (kind == 'danmaku') ...[
                      const SizedBox(width: AppSpacing.x2),
                      Text(
                        _time(comment.createdAt),
                        style: TextStyle(color: tokens.colors.text3, fontSize: 10),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  renderEmoji(comment.text),
                  style: TextStyle(color: tokens.colors.text, height: 1.45),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    InkWell(
                      onTap: onLike,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.x3),
                        child: Row(
                          children: [
                            Icon(
                              comment.liked
                                  ? Icons.thumb_up
                                  : Icons.thumb_up_outlined,
                              size: 14,
                              color: comment.liked
                                  ? tokens.colors.accent
                                  : tokens.colors.text3,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${comment.likeCount}',
                              style: TextStyle(
                                color: tokens.colors.text3,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (onReply != null)
                      InkWell(
                        onTap: onReply,
                        child: Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.x3),
                          child: Text(
                            '回复',
                            style: TextStyle(
                              color: tokens.colors.text3,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (onReplies != null)
                      InkWell(
                        onTap: onReplies,
                        child: Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.x3),
                          child: Text(
                            '查看${comment.replyCount}条回复',
                            style: TextStyle(
                              color: tokens.colors.accent,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (onDelete != null)
                      InkWell(
                        onTap: onDelete,
                        child: Text(
                          '删除',
                          style: TextStyle(
                            color: tokens.colors.text3,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _time(int ts) {
    if (ts <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${date.month}-${date.day}';
  }
}


/// Replies of one comment. The reply list has its own endpoint
/// (/reply/list/<comment_id>/v1/), so it stays a separate sheet.
class _ReplySheet extends StatefulWidget {
  const _ReplySheet({
    required this.api,
    required this.itemId,
    required this.episodeId,
    required this.kind,
    required this.comment,
  });

  final SourceApi api;
  final String itemId;
  final String episodeId;
  final String kind;
  final Comment comment;

  @override
  State<_ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends State<_ReplySheet> {
  List<Comment> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await widget.api.replies(
        itemId: widget.itemId,
        episodeId: widget.episodeId,
        kind: widget.kind,
        commentId: widget.comment.id,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeGatewayError(error);
        _loading = false;
      });
    }
  }

  Future<void> _like(Comment reply) async {
    final liked = !reply.liked;
    setState(() {
      _items = [
        for (final item in _items)
          if (item.id == reply.id)
            item.copyWith(
              liked: liked,
              likeCount: item.likeCount + (liked ? 1 : -1),
            )
          else
            item,
      ];
    });
    try {
      await widget.api.likeComment(
        reply.id,
        kind: widget.kind,
        liked: liked,
        itemId: widget.itemId,
        episodeId: widget.episodeId,
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _items = [
          for (final item in _items)
            if (item.id == reply.id) reply else item,
        ];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x4,
                AppSpacing.x3,
                AppSpacing.x2,
                AppSpacing.x1,
              ),
              child: Row(
                children: [
                  Text(
                    '回复 ${widget.comment.userName}',
                    style: TextStyle(
                      color: tokens.colors.text,
                      fontSize: AppFontSize.title,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.close, color: tokens.colors.text2),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                child: Text(
                  _error!,
                  style: TextStyle(color: tokens.colors.accent, fontSize: 12),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? Center(
                          child: Text(
                            '还没有回复',
                            style: TextStyle(color: tokens.colors.text3),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.x4,
                          ),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: tokens.colors.border,
                          ),
                          itemBuilder: (context, index) {
                            final reply = _items[index];
                            return _CommentRow(
                              comment: reply,
                              kind: widget.kind,
                              onLike: () => _like(reply),
                              onReply: null,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
