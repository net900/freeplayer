import 'package:flutter/material.dart';

import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../player/playback_engine.dart';
import '../sp/emoji.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.engine,
    required this.lines,
    required this.api,
    required this.itemId,
    required this.episodeId,
    this.onChanged,
    this.fontSize = 16,
    this.opacity = 1.0,
    this.speed = 1.0,
  });

  final PlaybackEngine engine;
  final List<DanmakuLine> lines;
  final SourceApi api;
  final String itemId;
  final String episodeId;
  final Future<void> Function()? onChanged;

  /// Display preferences from 弹幕设置.
  final double fontSize;
  final double opacity;
  final double speed;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer> {
  static const double _travel = 20;
  static const double _topHold = 8;

  DanmakuLine? _selected;
  double _frozenAge = 0;

  void _select(DanmakuLine line, double age) {
    setState(() {
      _selected = line;
      _frozenAge = age;
    });
  }

  void _clear() {
    if (_selected == null) return;
    setState(() => _selected = null);
  }

  Future<void> _reply(DanmakuLine line) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回复弹幕'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(
            hintText: '回复 ${line.userName.isEmpty ? '这条弹幕' : line.userName}',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await widget.api.replyComment(
        itemId: widget.itemId,
        commentId: line.id,
        episodeId: widget.episodeId,
        kind: 'danmaku',
        text: text.trim(),
        offsetSec: line.time.round(),
      );
      await widget.onChanged?.call();
      if (mounted) _clear();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeGatewayError(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: widget.engine.snapshot,
      builder: (context, snapshot, _) {
        final position = snapshot.position.inMilliseconds / 1000.0;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final fontSize = widget.fontSize;
            final travel = _travel / widget.speed.clamp(0.5, 2.5);
            final laneStep = fontSize + 14;
            final laneCount =
                (constraints.maxHeight * 0.35 / laneStep).clamp(2, 10).toInt();
            // Assign each line a lane once, in time order: a lane only takes a
            // new line after the previous one has moved far enough that the
            // texts cannot touch. Lines that find no free lane are skipped
            // instead of stacking on top of each other.
            final laneReady = List<double>.filled(laneCount, -1e9);
            final laneWidth = List<double>.filled(laneCount, 0);
            final laneOf = <DanmakuLine, int>{};
            final topOf = <DanmakuLine, int>{};
            final topReady = List<double>.filled(2, -1e9);
            final sorted = [...widget.lines]
              ..sort((a, b) => a.time.compareTo(b.time));
            for (final line in sorted) {
              if (line.mode == 'top') {
                var slot = -1;
                for (var i = 0; i < topReady.length; i++) {
                  if (line.time - topReady[i] >= _topHold) {
                    slot = i;
                    break;
                  }
                }
                if (slot < 0) continue;
                topReady[slot] = line.time;
                topOf[line] = slot;
                continue;
              }
              final textWidth =
                  (renderEmoji(line.text).runes.length * fontSize)
                      .clamp(40.0, width * 0.7);
              final speed = (width + textWidth) / travel;
              var lane = -1;
              for (var i = 0; i < laneCount; i++) {
                // The previous line's own width decides how long it still
                // covers the entrance, not the new line's width.
                final cleared = (line.time - laneReady[i]) * speed;
                if (cleared >= laneWidth[i] + 56) {
                  lane = i;
                  break;
                }
              }
              if (lane < 0) continue;
              laneReady[lane] = line.time;
              laneWidth[lane] = textWidth;
              laneOf[line] = lane;
            }
            final widgets = <Widget>[];
            for (final line in widget.lines) {
              final selected = identical(line, _selected);
              final age = selected ? _frozenAge : position - line.time;
              if (age < 0) continue;
              final color = _colorOf(line.color)
                  .withValues(alpha: widget.opacity.clamp(0.25, 1.0));
              if (line.mode == 'top') {
                final slot = topOf[line];
                if (slot == null || age > _topHold) continue;
                widgets.add(
                  Positioned(
                    top: 56 + slot * (fontSize + 18),
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        line.text,
                        style: TextStyle(
                          color: color,
                          fontSize: fontSize + 2,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
                continue;
              }
              final lane = laneOf[line];
              if (lane == null || (!selected && age > travel)) continue;
              final progress = age / travel;
              final text = Text(
                renderEmoji(line.text),
                style: TextStyle(
                  color: selected ? Colors.white : color,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  shadows: const [
                    Shadow(color: Colors.black, blurRadius: 6),
                  ],
                ),
              );
              widgets.add(
                Positioned(
                  top: 40 + lane * laneStep,
                  left: width * (1 - progress) - 40,
                  child: selected
                      ? MouseRegion(
                          onExit: (_) => _clear(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xCC000000),
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.sm),
                                ),
                                child: text,
                              ),
                              const SizedBox(height: 2),
                              _actions(line),
                            ],
                          ),
                        )
                      : MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => _select(line, position - line.time),
                          child: text,
                        ),
                ),
              );
            }
            return Stack(children: widgets);
          },
        );
      },
    );
  }

  Widget _actions(DanmakuLine line) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xE615181D),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => _reply(line),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 13,
                  color: Colors.white70,
                ),
                SizedBox(width: 3),
                Text(
                  '评论',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _colorOf(String raw) {
    final hex = raw.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null || hex.length != 6) return Colors.white;
    return Color(0xFF000000 | value);
  }
}

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key, this.label});

  /// Replaces the generic hint, e.g. while a bytevc2 episode is converted.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x59000000),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: AppSpacing.x3),
            Text(
              label ?? '加载中…',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: AppFontSize.xs,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerInfoCard extends StatefulWidget {
  const PlayerInfoCard({
    required this.item,
    required this.episodeLabel,
    required this.onOpenDetail,
    this.local = false,
  });

  final Item item;
  final String episodeLabel;
  final VoidCallback onOpenDetail;
  final bool local;

  @override
  State<PlayerInfoCard> createState() => _PlayerInfoCardState();
}

class _PlayerInfoCardState extends State<PlayerInfoCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onOpenDetail,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                decoration: _hover ? TextDecoration.underline : null,
                decorationColor: Colors.white70,
                shadows: const [Shadow(color: Color(0x99000000), blurRadius: 8)],
              ),
            ),
          ),
        ),
        if (widget.episodeLabel.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.episodeLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: AppFontSize.xs,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
                ),
              ),
              if (widget.local) ...[
                const SizedBox(width: AppSpacing.x2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x3327C48B),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: const Color(0x8827C48B)),
                  ),
                  child: const Text(
                    '本地',
                    style: TextStyle(
                      color: Color(0xFF7BE3B4),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            item.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: AppFontSize.xs,
              height: 1.45,
              shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
            ),
          ),
        ],
      ],
    );
  }
}

class EpisodeDrawer extends StatefulWidget {
  const EpisodeDrawer({
    required this.episodes,
    required this.currentId,
    required this.watched,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final String currentId;
  final Set<String> watched;
  final ValueChanged<Episode> onSelect;

  @override
  State<EpisodeDrawer> createState() => _EpisodeDrawerState();
}

class _EpisodeDrawerState extends State<EpisodeDrawer> {
  static const int _groupSize = 30;
  static const double _groupExtent = 360;

  final GlobalKey _currentKey = GlobalKey();
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final index =
        widget.episodes.indexWhere((episode) => episode.id == widget.currentId);
    final group = index < 0 ? 0 : index ~/ _groupSize;
    _controller = ScrollController(initialScrollOffset: group * _groupExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _currentKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 250),
          alignment: 0.35,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final episodes = widget.episodes;
    final groups = <List<Episode>>[];
    for (var i = 0; i < episodes.length; i += _groupSize) {
      groups.add(
        episodes.sublist(i, (i + _groupSize).clamp(0, episodes.length)),
      );
    }
    return Column(
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
              Text(
                '选集',
                style: TextStyle(
                  color: tokens.colors.text,
                  fontSize: AppFontSize.title,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                '共 ${episodes.length} 集',
                style: TextStyle(
                  color: tokens.colors.text3,
                  fontSize: AppFontSize.xs,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '关闭',
                color: tokens.colors.text2,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4,
              0,
              AppSpacing.x4,
              AppSpacing.x6,
            ),
            itemCount: groups.length,
            itemBuilder: (context, groupIndex) {
              final group = groups[groupIndex];
              final start = groupIndex * _groupSize + 1;
              final end = start + group.length - 1;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x2,
                    ),
                    child: Text(
                      '第$start-$end集',
                      style: TextStyle(
                        fontSize: AppFontSize.xxs,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: AppSpacing.x2,
                    runSpacing: AppSpacing.x2,
                    children: [
                      for (final episode in group)
                        _chip(context, episode),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, Episode episode) {
    final tokens = AppTokens.of(context);
    final selected = episode.id == widget.currentId;
    final watched = widget.watched.contains(episode.id);
    final fg = selected
        ? tokens.colors.accent
        : (watched ? tokens.colors.text : tokens.colors.text2);
    return GestureDetector(
      key: selected ? _currentKey : null,
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onSelect(episode),
      child: Container(
        width: 74,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected || watched
              ? tokens.colors.accentWeak
              : tokens.colors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected || watched
                ? tokens.colors.accent
                : tokens.colors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (watched && !selected) ...[
              Icon(Icons.check, size: 12, color: tokens.colors.accent),
              const SizedBox(width: 2),
            ],
            Flexible(
              child: Text(
                episode.title.isEmpty ? '${episode.index}' : episode.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppFontSize.xs, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerNotReady extends StatelessWidget {
  const PlayerNotReady({
    required this.error,
    required this.onBack,
    this.onRetry,
  });

  final String error;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xCC000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, color: Colors.white38, size: 44),
              const SizedBox(height: AppSpacing.x3),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: AppSpacing.x4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onRetry != null) ...[
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                  ],
                  // The overlay is always dark, so the outline button cannot
                  // take the theme's light-mode foreground (it vanished).
                  OutlinedButton(
                    onPressed: onBack,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
