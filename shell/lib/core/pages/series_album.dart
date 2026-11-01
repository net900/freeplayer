import 'package:flutter/material.dart';

import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/cover_image.dart';

/// 作品系列 sheet: the other works of a 合集. The player prefetches the list,
/// so this only renders what is already known — an empty album never opens.
///
/// Works that have not been released cannot be played: they offer 预约 instead,
/// and [reservedIds] marks the ones the account already reserved.
Future<void> showAlbumSheet(
  BuildContext context, {
  required List<Item> items,
  Set<String> reservedIds = const {},
  required ValueChanged<Item> onOpen,
  Future<bool> Function(Item item)? onReserve,
}) {
  final tokens = AppTokens.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: tokens.colors.surface,
    isScrollControlled: true,
    builder: (sheetContext) => _AlbumSheet(
      items: items,
      reservedIds: reservedIds,
      onOpen: onOpen,
      onReserve: onReserve,
    ),
  );
}

class _AlbumSheet extends StatefulWidget {
  const _AlbumSheet({
    required this.items,
    required this.reservedIds,
    required this.onOpen,
    required this.onReserve,
  });

  final List<Item> items;
  final Set<String> reservedIds;
  final ValueChanged<Item> onOpen;
  final Future<bool> Function(Item item)? onReserve;

  @override
  State<_AlbumSheet> createState() => _AlbumSheetState();
}

class _AlbumSheetState extends State<_AlbumSheet> {
  late final Set<String> _reserved;
  String _busyId = '';

  @override
  void initState() {
    super.initState();
    _reserved = {...widget.reservedIds};
  }

  Future<void> _reserve(Item item) async {
    final action = widget.onReserve;
    if (action == null || _busyId.isNotEmpty) return;
    setState(() => _busyId = item.id);
    try {
      if (await action(item) && mounted) {
        setState(() => _reserved.add(item.id));
      }
    } on Object {
      // The player shows its own notice for failures.
    } finally {
      if (mounted) setState(() => _busyId = '');
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
                AppSpacing.x2,
              ),
              child: Row(
                children: [
                  Text(
                    '作品系列',
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
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  0,
                  AppSpacing.x4,
                  AppSpacing.x6,
                ),
                itemCount: widget.items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.x2),
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  final current = item.extra['current'] == true;
                  final online = item.extra['is_online'] != false;
                  final reserved = _reserved.contains(item.id);
                  return AlbumRow(
                    item: item,
                    current: current,
                    online: online,
                    reserved: reserved,
                    busy: _busyId == item.id,
                    onTap: item.id == '' || current || !online
                        ? null
                        : () {
                            Navigator.of(context).maybePop();
                            widget.onOpen(item);
                          },
                    onReserve: online || widget.onReserve == null
                        ? null
                        : () => _reserve(item),
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

/// One row of the series list: cover, title, 当前 / 待上线 / 预约 state.
class AlbumRow extends StatelessWidget {
  const AlbumRow({
    super.key,
    required this.item,
    this.current = false,
    this.online = true,
    this.reserved = false,
    this.busy = false,
    this.onTap,
    this.onReserve,
  });

  final Item item;
  final bool current;
  final bool online;
  final bool reserved;
  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onReserve;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.x2),
        decoration: BoxDecoration(
          color: current ? tokens.colors.accentWeak : tokens.colors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 48,
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? tokens.colors.accent : tokens.colors.text,
                      fontSize: AppFontSize.body,
                    ),
                  ),
                  if (!online || item.updatedAt.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      !online ? '待上线${_publishHint(item)}' : item.updatedAt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.colors.text3,
                        fontSize: AppFontSize.xxs,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            if (current)
              _StatusText(text: '当前', color: tokens.colors.accent)
            else if (!online)
              SizedBox(
                height: 30,
                child: reserved
                    ? _StatusText(text: '已预约', color: tokens.colors.text3)
                    : FilledButton.tonal(
                        onPressed: busy ? null : onReserve,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.x3,
                          ),
                          minimumSize: const Size(0, 30),
                        ),
                        child: busy
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.5),
                              )
                            : const Text('预约', style: TextStyle(fontSize: AppFontSize.xs)),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  String _publishHint(Item item) {
    final raw = item.extra['publish_at'];
    if (raw is num && raw > 0) {
      final at = DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
      String two(int value) => value.toString().padLeft(2, '0');
      return ' · ${two(at.month)}-${two(at.day)}';
    }
    return '';
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(color: color, fontSize: AppFontSize.xxs),
    );
  }
}
