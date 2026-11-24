import 'package:flutter/material.dart';

import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'player_overlays.dart';

/// 清晰度选择：底部弹层，选中后交给调用方切换。
void showQualitySheet(
  BuildContext context, {
  required List<Stream> streams,
  required String current,
  required ValueChanged<Stream> onSelected,
}) {
  final tokens = AppTokens.of(context);
  showModalBottomSheet<void>(
    context: context,
    // Sources can expose a dozen lines; the list must scroll instead of
    // overflowing the sheet.
    isScrollControlled: true,
    backgroundColor: tokens.colors.surface,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.6,
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: Text('清晰度', style: TextStyle(color: tokens.colors.text)),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final stream in streams)
                  InkWell(
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onSelected(stream);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.x6,
                        vertical: AppSpacing.x3,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              stream.quality.isEmpty
                                  ? stream.id
                                  : stream.quality,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: stream.quality == current
                                    ? tokens.colors.accent
                                    : tokens.colors.text2,
                              ),
                            ),
                          ),
                          if (stream.quality == current)
                            Icon(
                              Icons.check,
                              size: 16,
                              color: tokens.colors.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
        ],
      ),
    ),
  );
}

/// 选集：从右侧滑出的抽屉，内部按 30 集分组并定位当前集。
void showEpisodesDrawer(
  BuildContext context, {
  required List<Episode> episodes,
  required String currentId,
  required Set<String> watched,
  required ValueChanged<Episode> onSelect,
}) {
  final tokens = AppTokens.of(context);
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '选集',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, _, __) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: tokens.colors.surface,
        child: SizedBox(
          width: 340,
          height: double.infinity,
          child: SafeArea(
            child: EpisodeDrawer(
              episodes: episodes,
              currentId: currentId,
              watched: watched,
              onSelect: (episode) {
                Navigator.of(dialogContext).pop();
                onSelect(episode);
              },
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (dialogContext, animation, _, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      );
    },
  );
}
