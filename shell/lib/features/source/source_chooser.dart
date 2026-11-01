import 'package:flutter/material.dart';

import '../../core/gateway/models.dart';
import '../../core/pages/loading.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../l10n/strings.dart';

/// The shelf of sources, shared by the first screen and the switch page.
///
/// The grid only holds things the user can enter: added sources and local
/// video. Adding lives in the header so it stays reachable when the list is
/// long; the dialog behind it asks whether the new entry is a network source
/// or a local script.
class SourceChooser extends StatelessWidget {
  const SourceChooser({
    super.key,
    required this.title,
    required this.subtitle,
    required this.sources,
    required this.activeSourceId,
    required this.localActive,
    required this.onSelect,
    required this.onOpenLocalFiles,
    required this.onAdd,
    this.recommended,
    this.onShowRecommended,
    this.onEdit,
    this.onDelete,
    this.busy = false,
    this.error,
    this.showBrand = false,
    this.maxWidth = 1000,
    this.status,
  });

  final String title;
  final String subtitle;
  final List<DiscoveredSource> sources;
  final String activeSourceId;
  final bool localActive;
  final Future<void> Function(DiscoveredSource source) onSelect;
  final Future<void> Function() onOpenLocalFiles;
  final Future<void> Function() onAdd;

  /// Inline recommended list; null hides it and shows the re-open action.
  final Widget? recommended;
  final Future<void> Function()? onShowRecommended;
  final Future<void> Function(DiscoveredSource source)? onEdit;
  final Future<void> Function(DiscoveredSource source)? onDelete;
  final bool busy;
  final String? error;
  final bool showBrand;
  final double maxWidth;

  /// One line while the bundled core is still starting.
  final String? status;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showBrand) ...[
              const _BrandMark(),
              const SizedBox(height: AppSpacing.x6),
            ],
            _Header(
              title: title,
              subtitle: subtitle,
              status: status,
              busy: busy,
              onAdd: onAdd,
            ),
            const SizedBox(height: AppSpacing.x6),
            if (recommended != null) ...[
              recommended!,
              const SizedBox(height: AppSpacing.x6),
            ] else if (onShowRecommended != null) ...[
              _ShowRecommendedButton(onTap: onShowRecommended!),
              const SizedBox(height: AppSpacing.x4),
            ],
            _SourceGrid(
              sources: sources,
              activeSourceId: activeSourceId,
              localActive: localActive,
              busy: busy,
              onSelect: onSelect,
              onOpenLocalFiles: onOpenLocalFiles,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
            if (busy) ...[
              const SizedBox(height: AppSpacing.x4),
              const LoadingLine(compact: true),
            ],
            if (error != null) ...[
              const SizedBox(height: AppSpacing.x3),
              Text(
                error!,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  color: tokens.colors.danger,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.busy,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final String? status;
  final bool busy;
  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 32,
            height: 1.12,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
            color: tokens.colors.text,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: AppFontSize.body,
            height: AppLineHeight.body,
            color: tokens.colors.text2,
          ),
        ),
        if (status != null) ...[
          const SizedBox(height: AppSpacing.x3),
          Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: tokens.colors.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                status!,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  color: tokens.colors.text3,
                ),
              ),
            ],
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final add = _AddButton(busy: busy, onTap: onAdd);
        if (constraints.maxWidth < 540) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleBlock,
              const SizedBox(height: AppSpacing.x4),
              add,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: titleBlock),
            const SizedBox(width: AppSpacing.x4),
            add,
          ],
        );
      },
    );
  }
}

class _AddButton extends StatefulWidget {
  const _AddButton({required this.busy, required this.onTap});

  final bool busy;
  final Future<void> Function() onTap;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final enabled = !widget.busy;
    final background = !enabled
        ? tokens.colors.surface3
        : _hovered
            ? tokens.colors.accent.withValues(alpha: 0.18)
            : tokens.colors.accentWeak;
    final foreground = enabled ? tokens.colors.accent : tokens.colors.text3;

    return Tooltip(
      message: '添加源',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: background,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          animationDuration: AppDuration.micro,
          child: InkWell(
            onTap: enabled ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x2 + 2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 18, color: foreground),
                  const SizedBox(width: AppSpacing.x1 + 2),
                  Text(
                    '添加源',
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.sources,
    required this.activeSourceId,
    required this.localActive,
    required this.busy,
    required this.onSelect,
    required this.onOpenLocalFiles,
    this.onEdit,
    this.onDelete,
  });

  final List<DiscoveredSource> sources;
  final String activeSourceId;
  final bool localActive;
  final bool busy;
  final Future<void> Function(DiscoveredSource source) onSelect;
  final Future<void> Function() onOpenLocalFiles;
  final Future<void> Function(DiscoveredSource source)? onEdit;
  final Future<void> Function(DiscoveredSource source)? onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileCount = sources.length + 1;
        var columns = constraints.maxWidth >= 760
            ? 3
            : constraints.maxWidth >= 520
                ? 2
                : 1;
        if (columns > tileCount) columns = tileCount;
        final rawWidth =
            (constraints.maxWidth - AppSpacing.x4 * (columns - 1)) / columns;
        final tileWidth = rawWidth > 340 ? 340.0 : rawWidth;

        return Wrap(
          spacing: AppSpacing.x4,
          runSpacing: AppSpacing.x4,
          children: [
            for (final source in sources)
              _SourceTile(
                width: tileWidth,
                source: source,
                active: source.sourceId == activeSourceId,
                busy: busy,
                onTap: () => onSelect(source),
                menu: onEdit == null && onDelete == null
                    ? null
                    : _TileMenu(
                        onEdit: onEdit == null || source.isLocal
                            ? null
                            : () => onEdit!(source),
                        onDelete:
                            onDelete == null ? null : () => onDelete!(source),
                      ),
              ),
            _LocalVideoTile(
              width: tileWidth,
              active: localActive,
              busy: busy,
              onTap: onOpenLocalFiles,
            ),
          ],
        );
      },
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.width,
    required this.source,
    required this.active,
    required this.busy,
    required this.onTap,
    this.menu,
  });

  final double width;
  final DiscoveredSource source;
  final bool active;
  final bool busy;
  final Future<void> Function() onTap;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final name = source.name.isEmpty ? source.sourceId : source.name;
    final initial = name.characters.isEmpty ? '源' : name.characters.first;
    return _Tile(
      width: width,
      active: active,
      busy: busy,
      onTap: onTap,
      glyph: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: source.isLocal
              ? tokens.colors.surface3
              : tokens.colors.accentWeak,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: source.isLocal ? tokens.colors.text2 : tokens.colors.accent,
          ),
        ),
      ),
      title: name,
      description: source.description.trim().isEmpty
          ? (source.isLocal ? '在客户端内运行' : '网络源')
          : source.description.trim(),
      typeLabel: source.isLocal ? '本地源' : '网络源',
      menu: menu,
    );
  }
}

class _LocalVideoTile extends StatelessWidget {
  const _LocalVideoTile({
    required this.width,
    required this.active,
    required this.busy,
    required this.onTap,
  });

  final double width;
  final bool active;
  final bool busy;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return _Tile(
      width: width,
      active: active,
      busy: busy,
      onTap: onTap,
      glyph: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: tokens.colors.surface3,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(
          Icons.folder_open,
          size: 21,
          color: tokens.colors.text2,
        ),
      ),
      title: '本机视频',
      description: '播放电脑上的视频文件，不使用内容源',
      typeLabel: '本机',
    );
  }
}

class _Tile extends StatefulWidget {
  const _Tile({
    required this.width,
    required this.active,
    required this.busy,
    required this.onTap,
    required this.glyph,
    required this.title,
    required this.description,
    required this.typeLabel,
    this.menu,
  });

  final double width;
  final bool active;
  final bool busy;
  final Future<void> Function() onTap;
  final Widget glyph;
  final String title;
  final String description;
  final String typeLabel;
  final Widget? menu;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final enabled = !widget.busy;
    final background = widget.active
        ? tokens.colors.accentWeak.withValues(alpha: 0.35)
        : _hovered
            ? tokens.colors.surface3.withValues(alpha: 0.5)
            : tokens.colors.surface2.withValues(alpha: 0.55);
    final border = widget.active
        ? tokens.colors.accent
        : _hovered
            ? tokens.colors.text3
            : tokens.colors.border;

    return SizedBox(
      width: widget.width,
      height: 138,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          animationDuration: AppDuration.micro,
          child: InkWell(
            onTap: enabled ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x3 + 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      widget.glyph,
                      const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppFontSize.bodyLg,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                if (widget.active) ...[
                                  const SizedBox(width: AppSpacing.x2),
                                  _Tag(
                                    label: '使用中',
                                    color: tokens.colors.accentWeak,
                                    textColor: tokens.colors.accent,
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: AppSpacing.x1),
                            Text(
                              widget.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppFontSize.xs,
                                height: 1.5,
                                color: tokens.colors.text3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.menu != null) ...[
                        const SizedBox(width: AppSpacing.x1),
                        widget.menu!,
                      ],
                    ],
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Text(
                        widget.typeLabel,
                        style: TextStyle(
                          fontSize: AppFontSize.xxs,
                          color: tokens.colors.text3,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: widget.active
                            ? tokens.colors.accent
                            : tokens.colors.text3,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x1,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppFontSize.xxs,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({this.onEdit, this.onDelete});

  final Future<void> Function()? onEdit;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return PopupMenuButton<String>(
      tooltip: '管理这个源',
      padding: EdgeInsets.zero,
      color: tokens.colors.surface2,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(Icons.more_horiz, size: 18, color: tokens.colors.text3),
      ),
      onSelected: (value) {
        if (value == 'edit') onEdit?.call();
        if (value == 'delete') onDelete?.call();
      },
      itemBuilder: (context) => [
        if (onEdit != null)
          const PopupMenuItem(value: 'edit', child: Text('编辑地址')),
        if (onDelete != null)
          PopupMenuItem(
            value: 'delete',
            child: Text(
              '删除',
              style: TextStyle(color: tokens.colors.danger),
            ),
          ),
      ],
    );
  }
}

class _ShowRecommendedButton extends StatefulWidget {
  const _ShowRecommendedButton({required this.onTap});

  final Future<void> Function() onTap;

  @override
  State<_ShowRecommendedButton> createState() => _ShowRecommendedButtonState();
}

class _ShowRecommendedButtonState extends State<_ShowRecommendedButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: _hovered
              ? tokens.colors.surface3.withValues(alpha: 0.4)
              : Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x3,
                vertical: AppSpacing.x2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.verified_outlined,
                    size: 17,
                    color: tokens.colors.accent,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Text(
                    '显示官方推荐源',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      fontWeight: FontWeight.w600,
                      color: tokens.colors.text2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: tokens.colors.accentWeak,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(
            Icons.play_circle_fill,
            size: 19,
            color: tokens.colors.accent,
          ),
        ),
        const SizedBox(width: AppSpacing.x2),
        Text(
          AppStrings.appName,
          style: TextStyle(
            fontSize: AppFontSize.xs,
            fontWeight: FontWeight.w600,
            color: tokens.colors.text3,
          ),
        ),
      ],
    );
  }
}
