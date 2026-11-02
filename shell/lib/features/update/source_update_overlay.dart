import 'package:flutter/material.dart';

import '../../core/gateway/core_download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

/// Blocks the window while the core DLL or a local source is being replaced.
///
/// Updates used to swap files under a running UI and leave a "restart me"
/// hint; the user could keep browsing a half-updated app and never restart.
/// Showing the transfer, then restarting on our own, keeps the state honest.
class SourceUpdateOverlay extends StatelessWidget {
  const SourceUpdateOverlay({
    super.key,
    required this.names,
    required this.progress,
    required this.restarting,
  });

  final List<String> names;
  final CoreDownloadState? progress;
  final bool restarting;

  String get _title {
    if (restarting) return '更新完成，正在重启程序';
    if (names.isEmpty) return '正在检查更新';
    return '正在更新 ${names.join('、')}';
  }

  String? get _detail {
    if (restarting) return '请稍候，程序会自动打开';
    final state = progress;
    if (state == null) return '正在下载…';
    final got = (state.received / (1 << 20)).toStringAsFixed(1);
    if (state.total <= 0) return '已下载 $got MB';
    final all = (state.total / (1 << 20)).toStringAsFixed(1);
    final pct = (state.received * 100 / state.total).clamp(0, 100).toStringAsFixed(0);
    return '$got / $all MB（$pct%）';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final colors = tokens.colors;
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xB3000000),
        child: Center(
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(AppSpacing.x6),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      restarting ? Icons.autorenew : Icons.downloading,
                      size: 18,
                      color: colors.accent,
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: Text(
                        _title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.bodyLg,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    value: restarting ? null : progress?.fraction,
                    minHeight: 4,
                    backgroundColor: colors.surface2,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                Text(
                  _detail ?? '',
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    color: colors.text3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
