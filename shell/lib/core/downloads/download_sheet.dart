import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../gateway/source_api.dart';
import '../sp/models.dart';
import '../sp/quality.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'download_manager.dart';

/// Picks episodes and a quality, queues them in [DownloadManager] and returns
/// how many were queued (0 when dismissed).
Future<int> showDownloadSheet(
  BuildContext context, {
  required SourceApi api,
  required Item item,
  required List<Episode> episodes,
  String initialEpisodeId = '',
  String cover = '',
}) async {
  final queued = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.of(context).colors.surface,
    builder: (_) => _DownloadSheet(
      api: api,
      item: item,
      episodes: episodes,
      initialEpisodeId: initialEpisodeId,
      cover: cover,
    ),
  );
  return queued ?? 0;
}

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({
    required this.api,
    required this.item,
    required this.episodes,
    required this.initialEpisodeId,
    required this.cover,
  });

  final SourceApi api;
  final Item item;
  final List<Episode> episodes;
  final String initialEpisodeId;
  final String cover;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  String _quality = Quality.auto;
  bool _ready = false;
  final Set<String> _selected = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _quality = AppScope.controllerOf(context).settings.downloadQuality;
    if (widget.initialEpisodeId.isNotEmpty) {
      _selected.add(widget.initialEpisodeId);
    } else if (widget.episodes.isNotEmpty) {
      _selected.add(widget.episodes.first.id);
    }
  }

  String get _seriesKey => '${widget.api.sourceId}:${widget.item.id}';

  bool _downloaded(Episode episode) =>
      AppScope.of(context).downloads.localPathFor(_seriesKey, episode.id) !=
      null;

  void _submit() {
    if (_selected.isEmpty) return;
    final tasks = <DownloadTask>[];
    for (final episode in widget.episodes) {
      if (!_selected.contains(episode.id)) continue;
      tasks.add(DownloadTask(
        itemId: widget.item.id,
        episodeId: episode.id,
        seriesKey: _seriesKey,
        title: widget.item.title,
        episodeLabel:
            episode.title.isEmpty ? '第${episode.index}集' : episode.title,
        quality: _quality,
        cover: widget.cover.isEmpty ? widget.item.cover : widget.cover,
        episodeIndex: episode.index,
      ));
    }
    AppScope.of(context).downloads.enqueueAll(widget.api, tasks);
    Navigator.of(context).pop(tasks.length);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final downloaded = widget.episodes.where(_downloaded).length;
    final available = widget.episodes.where((e) => !_downloaded(e)).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.66,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                    '下载',
                    style: TextStyle(
                      color: tokens.colors.text,
                      fontSize: AppFontSize.title,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.colors.text3,
                        fontSize: AppFontSize.xs,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(0),
                    icon: Icon(Icons.close, color: tokens.colors.text2),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.colors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: tokens.colors.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '画质',
                          style: TextStyle(
                            fontSize: AppFontSize.xxs,
                            color: tokens.colors.text3,
                          ),
                        ),
                        const SizedBox(width: 4),
                        DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: Quality.options.contains(_quality)
                                ? _quality
                                : Quality.auto,
                            isDense: true,
                            dropdownColor: tokens.colors.surface2,
                            style: TextStyle(
                              fontSize: AppFontSize.xs,
                              color: tokens.colors.text,
                            ),
                            items: [
                              for (final option in Quality.options)
                                DropdownMenuItem(
                                  value: option,
                                  child: Text(
                                    option == Quality.auto ? '最高' : option,
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _quality = value);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    downloaded > 0
                        ? '共 ${widget.episodes.length} 集 · $downloaded 已下载'
                        : '共 ${widget.episodes.length} 集',
                    style: TextStyle(
                      fontSize: AppFontSize.xxs,
                      color: tokens.colors.text3,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x4,
                AppSpacing.x1,
                AppSpacing.x4,
                0,
              ),
              child: Row(
                children: [
                  Text(
                    '选集',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      fontWeight: FontWeight.w600,
                      color: tokens.colors.text2,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == available.length) {
                        _selected.removeAll(available.map((e) => e.id));
                      } else {
                        _selected
                          ..clear()
                          ..addAll(available.map((e) => e.id));
                      }
                    }),
                    child: Text(
                      _selected.length == available.length ? '清空' : '全选',
                      style: const TextStyle(fontSize: AppFontSize.xs),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  0,
                  AppSpacing.x4,
                  AppSpacing.x2,
                ),
                children: [
                  Wrap(
                    spacing: AppSpacing.x2,
                    runSpacing: AppSpacing.x2,
                    children: [
                      for (final episode in widget.episodes)
                        _EpisodeChip(
                          label: episode.index > 0
                              ? '${episode.index}'
                              : episode.title,
                          selected: _selected.contains(episode.id),
                          downloaded: _downloaded(episode),
                          onTap: _downloaded(episode)
                              ? null
                              : () => setState(() {
                                    if (!_selected.remove(episode.id)) {
                                      _selected.add(episode.id);
                                    }
                                  }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x4,
                AppSpacing.x2,
                AppSpacing.x4,
                AppSpacing.x3,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: tokens.colors.border),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    '已选 ${_selected.length} 集',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.text2,
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _selected.isEmpty ? null : _submit,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('开始下载'),
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

/// One episode as a square-ish chip: number, selection, downloaded state.
class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    required this.label,
    required this.selected,
    required this.downloaded,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool downloaded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final color = downloaded
        ? tokens.colors.text3
        : selected
            ? tokens.colors.accent
            : tokens.colors.text2;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 46,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? tokens.colors.accentWeak
              : tokens.colors.surface2.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? tokens.colors.accent : tokens.colors.border,
          ),
        ),
        child: downloaded
            ? Icon(Icons.check, size: 15, color: color)
            : Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
      ),
    );
  }
}
