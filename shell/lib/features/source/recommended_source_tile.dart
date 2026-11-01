import 'package:flutter/material.dart';

import '../../core/gateway/recommended_sources.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

/// One recommendation row, shared by the add dialog and the inline panel.
class RecommendedSourceTile extends StatelessWidget {
  const RecommendedSourceTile({
    super.key,
    required this.source,
    required this.added,
    required this.updateAvailable,
    required this.busy,
    required this.disabled,
    required this.onAdd,
  });

  final RecommendedSource source;
  final bool added;
  final bool updateAvailable;
  final bool busy;
  final bool disabled;
  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final initial =
        source.name.characters.isEmpty ? '源' : source.name.characters.first;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x3,
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x3,
      ),
      decoration: BoxDecoration(
        color: tokens.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.colors.accentWeak,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: tokens.colors.accent,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (source.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      source.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppFontSize.xs,
                        height: 1.5,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          _TileAction(
            added: added,
            updateAvailable: updateAvailable,
            busy: busy,
            disabled: disabled,
            local: source.isLocal,
            onAdd: onAdd,
          ),
        ],
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.added,
    required this.updateAvailable,
    required this.busy,
    required this.disabled,
    required this.local,
    required this.onAdd,
  });

  final bool added;
  final bool updateAvailable;
  final bool busy;
  final bool disabled;
  final bool local;
  final Future<void> Function() onAdd;

  static const _padding = EdgeInsets.symmetric(horizontal: 12);
  static const _size = Size(0, 34);

  @override
  Widget build(BuildContext context) {
    final label = Text(
      added && !updateAvailable
          ? (local ? '已安装' : '已添加')
          : updateAvailable
              ? '更新'
              : (local ? '下载' : '添加'),
      maxLines: 1,
      softWrap: false,
    );
    if (added && !updateAvailable) {
      return OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          padding: _padding,
          minimumSize: _size,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: label,
      );
    }
    return FilledButton(
      onPressed: disabled ? null : onAdd,
      style: FilledButton.styleFrom(
        padding: _padding,
        minimumSize: _size,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : label,
    );
  }
}

String normalizeSourceUrl(String value) {
  var result = value.trim();
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
