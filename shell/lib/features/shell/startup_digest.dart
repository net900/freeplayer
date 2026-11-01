import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/gateway/source_api.dart';
import '../../core/library/local_library.dart';
import '../../core/sp/models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/storage/local_store.dart';
import '../../core/storage/paths.dart';
import '../../core/widgets/cover_image.dart';

/// Remembers which update/premiere prompts were already shown, so a startup
/// digest only reports new episodes and newly-released reservations.
class DigestSeen {
  DigestSeen(this._store);

  final LocalStore _store;

  static const String _key = 'seen';

  Future<Map<String, String>> _loadAll() async {
    final data = await _store.read();
    final raw = data[_key];
    final out = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) => out[key.toString()] = value.toString());
    }
    return out;
  }

  Future<Set<String>> load() async => (await _loadAll()).keys.toSet();

  Future<void> mark(Iterable<String> keys) async {
    if (keys.isEmpty) return;
    final all = await _loadAll();
    final today = DateTime.now().toIso8601String();
    for (final key in keys) {
      all[key] = today;
    }
    // Prune prompts older than 45 days so the file stays small.
    final cutoff = DateTime.now().subtract(const Duration(days: 45));
    all.removeWhere((_, value) {
      final at = DateTime.tryParse(value);
      return at != null && at.isBefore(cutoff);
    });
    await _store.write({_key: all});
  }
}

class StartupDigest {
  StartupDigest({
    required this.updated,
    required this.premiered,
    required this.last,
    required this.newKeys,
    required this.seen,
  });

  final List<Item> updated;
  final List<Item> premiered;
  final LibraryRecord? last;
  final List<String> newKeys;
  final DigestSeen seen;

  bool get isEmpty => updated.isEmpty && premiered.isEmpty && last == null;

  Future<void> markSeen() => seen.mark(newKeys);
}

/// Collects what changed since the last launch. Only new prompts are returned;
/// the "continue watching" card appears when there is nothing else to report.
Future<StartupDigest> loadStartupDigest(
  SourceApi api,
  LocalLibrary library,
) async {
  final seen = DigestSeen(LocalStore(appDataFile('digest_seen.json')));
  final shown = await seen.load();
  final updated = <Item>[];
  final premiered = <Item>[];
  final keys = <String>[];

  try {
    final page = await api.follows(limit: 50);
    for (final item in page.items) {
      final index = intOr(item.extra['vid_index']);
      final count = intOr(item.extra['episode_count']);
      if (index <= 0 || count <= 0 || index >= count) continue;
      final key = 'follow:${item.id}:$count';
      if (shown.contains(key)) continue;
      updated.add(item);
      keys.add(key);
    }
  } on Object {
    // Follows need login; an expired session simply yields no prompt.
  }

  try {
    final page = await api.reservations(limit: 50, online: true);
    for (final item in page.items) {
      if (item.extra['is_online'] == false) continue;
      final key = 'premiere:${item.id}';
      if (shown.contains(key)) continue;
      premiered.add(item);
      keys.add(key);
    }
  } on Object {
    // Reservations are optional.
  }

  LibraryRecord? last;
  if (updated.isEmpty && premiered.isEmpty) {
    try {
      final history = await library.history();
      for (final record in history) {
        if (record.sourceId == api.sourceId) {
          last = record;
          break;
        }
      }
    } on Object {
      // No local history.
    }
  }

  return StartupDigest(
    updated: updated,
    premiered: premiered,
    last: last,
    newKeys: keys,
    seen: seen,
  );
}

/// "Welcome back" as a small frosted banner at the top: the page behind it
/// stays usable, and the banner clears itself after a few seconds.
Future<void> showStartupDigest(
  BuildContext context,
  StartupDigest digest, {
  required ValueChanged<Item> onOpenItem,
  required ValueChanged<LibraryRecord> onContinue,
  required VoidCallback onOpenFollow,
  required VoidCallback onOpenHistory,
}) {
  if (digest.isEmpty) return Future<void>.value();
  final tokens = AppTokens.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;

  final updated = digest.updated;
  final premiered = digest.premiered;
  final last = digest.last;
  final item = updated.isNotEmpty
      ? updated.first
      : premiered.isNotEmpty
          ? premiered.first
          : null;
  final String eyebrow;
  final String title;
  final String subtitle;
  if (updated.isNotEmpty) {
    eyebrow = updated.length == 1 ? '追更更新' : '追更更新 · ${updated.length} 部';
    title = updated.length == 1 ? updated.first.title : '${updated.length} 部追更剧更新了';
    subtitle = updated.length == 1 ? _episodeLine(updated.first) : '点击查看最新一集';
  } else if (premiered.isNotEmpty) {
    eyebrow = '预约上线';
    title = premiered.length == 1
        ? '《${premiered.first.title}》已上线'
        : '${premiered.length} 部预约剧已上线';
    subtitle = '点击查看';
  } else {
    eyebrow = '继续观看';
    title = '上次看到《${last!.title}》'
        '${last.episodeIndex > 0 ? ' 第${last.episodeIndex}集' : ''}';
    subtitle = '点击继续播放';
  }

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '欢迎回来',
    barrierColor: Colors.transparent,
    transitionDuration: AppDuration.overlay,
    pageBuilder: (dialogContext, _, __) {
      void openPrimary() {
        Navigator.of(dialogContext).pop();
        if (item != null) {
          onOpenItem(item);
        } else if (last != null) {
          onContinue(last);
        }
      }

      return Stack(
        children: [
          Align(
            alignment: Alignment.bottomCenter,
            child: _AutoClose(
              duration: const Duration(seconds: 5),
              child: _GlassBanner(
                dark: dark,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: InkWell(
                            onTap: openPrimary,
                            borderRadius:
                                BorderRadius.circular(AppRadius.md),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.x3,
                                vertical: AppSpacing.x2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (item != null)
                                    SizedBox(
                                      width: 34,
                                      height: 44,
                                      child: CoverImage(
                                        url: item.cover,
                                        seed: item.title,
                                        radius: AppRadius.sm,
                                      ),
                                    )
                                  else
                                    Icon(
                                      Icons.play_circle_outline,
                                      size: 28,
                                      color: tokens.colors.accent,
                                    ),
                                  const SizedBox(width: AppSpacing.x3),
                                  Flexible(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          eyebrow,
                                          style: TextStyle(
                                            fontSize: AppFontSize.xxs,
                                            fontWeight: FontWeight.w700,
                                            color: tokens.colors.accent,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppFontSize.body,
                                            fontWeight: FontWeight.w600,
                                            color: tokens.colors.text,
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppFontSize.xxs,
                                            color: tokens.colors.text3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: tokens.colors.text3,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x1),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, _, child) {
      final curved = CurveTween(curve: Curves.easeOutCubic).animate(animation);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The digest is a glance, not a task: it closes itself after a few seconds.
class _AutoClose extends StatefulWidget {
  const _AutoClose({
    required this.child,
    this.duration = const Duration(seconds: 5),
  });

  final Widget child;
  final Duration duration;

  @override
  State<_AutoClose> createState() => _AutoCloseState();
}

class _AutoCloseState extends State<_AutoClose> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, () {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.isCurrent ?? false) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String _episodeLine(Item item) {
  final index = intOr(item.extra['vid_index']);
  final count = intOr(item.extra['episode_count']);
  if (index > 0 && count > 0) return '更新至第$index集 · 共$count集';
  if (count > 0) return '共$count集';
  return '有新内容';
}

class _GlassBanner extends StatelessWidget {
  const _GlassBanner({required this.dark, required this.child});

  final bool dark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x4,
        0,
        AppSpacing.x4,
        AppSpacing.x12,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                color: (dark ? Colors.black : Colors.white)
                    .withValues(alpha: dark ? 0.62 : 0.74),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: (dark ? Colors.white : Colors.black)
                      .withValues(alpha: dark ? 0.14 : 0.08),
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
