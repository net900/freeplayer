import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../gateway/source_api.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';
import '../widgets/editorial.dart';
import 'common.dart';
import 'loading.dart';
import 'navigation.dart';
import 'route.dart';
import 'search_page.dart';

/// Ranking page: three selector levels supplied by the source.
class RankPage extends StatefulWidget {
  const RankPage({super.key, required this.ctx, this.api});

  final PageContext ctx;

  /// Test seam: bypasses AppScope when provided.
  final SourceApi? api;

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  final Map<String, Set<String>> _selected = {};
  final List<Item> _items = [];
  final ScrollController _scroll = ScrollController();
  RankMeta? _meta;
  String _next = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _metaLoading = true;
  bool _metaFailed = false;
  bool _filtersOpen = false;
  bool _started = false;
  String? _error;
  int _epoch = 0;
  int _metaEpoch = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Load the ranking immediately; the filter panel arrives separately so a
    // slow /rank/meta never blocks the list.
    _load(reset: true);
    _loadMeta();
  }

  /// Fill the first screen or two before the reader reaches the end.
  /// Scroll extent for a lazily built list is only estimated until the user
  /// scrolls, so the item count — not maxScrollExtent — is the reliable signal.
  void _fillIfNeeded() {
    if (!mounted || _next.isEmpty || _loading || _loadingMore) return;
    if (_items.length < 20) {
      _load();
      return;
    }
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent <= position.viewportDimension) _load();
  }

  void _prefetch(int index) {
    if (_next.isEmpty || _loadingMore || _loading) return;
    if (index < _items.length ~/ 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  SourceApi? get _api =>
      widget.api ?? AppScope.controllerOf(context).sourceApi;

  String _join(String key) => (_selected[key] ?? const <String>{}).join(',');

  String _first(String key) {
    final set = _selected[key];
    return set == null || set.isEmpty ? '' : set.first;
  }

  /// The gender/theme panel is per board; resend it whenever outer/sub moves.
  Future<void> _loadMeta({String? type, String? sub}) async {
    final api = _api;
    if (api == null) return;
    final epoch = ++_metaEpoch;
    try {
      final meta = await api.rankMeta(
        type: type ?? _join('outer'),
        sub: sub ?? _join('sub'),
      );
      if (!mounted || epoch != _metaEpoch) return;
      setState(() {
        _meta = meta;
        _metaLoading = false;
        final keys = meta.groups.map((group) => group.key).toSet();
        _selected.removeWhere((key, _) => !keys.contains(key));
        for (final group in meta.groups) {
          final kept = _selected[group.key] ?? const <String>{};
          final valid = kept.isNotEmpty &&
              kept.every((id) => group.options.any((o) => o.id == id));
          if (!valid) {
            final def = meta.defaults[group.key] ?? '';
            _selected[group.key] = def.isEmpty ? <String>{} : {def};
          }
        }
        // A board belongs to exactly one outer type. If the previous board
        // does not belong to the newly selected type, pick its first board.
        final outer = _selected['outer'] ?? const <String>{};
        final activeOuter =
            outer.isNotEmpty ? outer.first : (meta.defaults['outer'] ?? '');
        FilterGroup? subGroup;
        for (final group in meta.groups) {
          if (group.key == 'sub') subGroup = group;
        }
        if (subGroup != null && activeOuter.isNotEmpty) {
          final kept = _selected['sub'] ?? const <String>{};
          final valid = kept.any(
            (id) => subGroup!.options.any(
              (option) =>
                  option.id == id &&
                  (option.parent.isEmpty || option.parent == activeOuter),
            ),
          );
          if (!valid) {
            var next = '';
            for (final option in subGroup.options) {
              if (option.parent == activeOuter) {
                next = option.id;
                break;
              }
            }
            if (next.isEmpty) {
              for (final option in subGroup.options) {
                if (option.parent.isEmpty) {
                  next = option.id;
                  break;
                }
              }
            }
            _selected['sub'] = next.isEmpty ? <String>{} : {next};
          }
        }
      });
    } on Object {
      if (!mounted || epoch != _metaEpoch) return;
      setState(() {
        _metaLoading = false;
        _metaFailed = true;
      });
    }
  }

  void _openRankItem(BuildContext context, SourceApi api, Item item) {
    // 演员榜 rows are people: show their works through search instead of
    // opening a series detail.
    if (item.type == 'actor') {
      Navigator.of(context).push(
        instantRoute(
          (_) => OpaquePage(child: SearchPage(initialQuery: item.title)),
        ),
      );
      return;
    }
    openDetail(context, api, item);
  }

  String get _panelParam {
    final meta = _meta;
    if (meta == null) return '';
    for (final group in meta.groups) {
      if (!group.key.startsWith('panel_')) continue;
      for (final id in _selected[group.key] ?? const <String>{}) {
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  Future<void> _load({bool reset = false}) async {
    final api = _api;
    if (api == null) return;
    // The guard must run before the epoch bump: otherwise a scroll notification
    // during an in-flight page silently invalidates its response and the list
    // stalls on page one.
    if (!reset && (_loadingMore || _next.isEmpty)) return;
    final epoch = ++_epoch;
    if (reset) {
      setState(() {
        _items.clear();
        _next = '';
        _loading = true;
        _loadingMore = false;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await api.rank(
        type: _first('outer'),
        sub: _first('sub'),
        panel: _panelParam,
        cursor: reset ? '' : _next,
        limit: 20,
      );
      if (!mounted) return;
      if (epoch != _epoch) {
        // A newer listing owns the screen: this response must not leave the
        // pagination flag stuck for it.
        setState(() => _loadingMore = false);
        return;
      }
      final seen = _items.map((item) => item.id).toSet();
      setState(() {
        _items.addAll(page.items.where((item) => !seen.contains(item.id)));
        _next = page.next;
        _loading = false;
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillIfNeeded());
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _pick(FilterGroup group, String value) {
    final key = group.key;
    final current = _selected[key] ?? <String>{};
    if (!group.multi && current.length == 1 && current.first == value) return;
    setState(() {
      if (key.startsWith('panel_')) {
        // One panel filter at a time: the upstream accepts a single id.
        _clearPanels();
        _selected[key] = value.isEmpty ? <String>{} : {value};
      } else if (group.multi) {
        final next = Set<String>.from(current);
        if (!next.remove(value)) next.add(value);
        _selected[key] = next;
      } else {
        _selected[key] = value.isEmpty ? <String>{} : {value};
      }
      if (key == 'outer') {
        // The board list and its panel both depend on the outer row.
        final next = _firstChild(value);
        _selected['sub'] = next == null ? <String>{} : {next};
        _clearPanels();
        _loadMeta(type: value, sub: next ?? '');
      } else if (key == 'sub') {
        _clearPanels();
        _loadMeta(type: _first('outer'), sub: value);
      }
    });
    _load(reset: true);
  }

  void _clearPanels() {
    for (final group in _meta?.groups ?? const <FilterGroup>[]) {
      if (group.key.startsWith('panel_')) _selected[group.key] = <String>{};
    }
  }

  String? _firstChild(String parent) {
    final meta = _meta;
    if (meta == null) return null;
    // The sub group reports every board for every outer with a `parent`
    // marker; dependsOn is empty. Match by parent.
    for (final group in meta.groups) {
      if (group.key != 'sub' && group.dependsOn != 'outer') continue;
      for (final option in group.options) {
        if (option.parent == parent) return option.id;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    if (api == null) {
      return const StatePanel(
        icon: Icons.leaderboard_outlined,
        title: AppStrings.emptyTitle,
        body: AppStrings.emptyBody,
      );
    }
    final tokens = AppTokens.of(context);
    final panelGroups = (_meta?.groups ?? const <FilterGroup>[])
        .where((group) => group.key != 'outer' && group.key != 'sub')
        .toList(growable: false);
    return ContentFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: AppStrings.navRank),
          if (_metaLoading) const LinearProgressIndicator(minHeight: 2),
          if (_meta != null && !_metaLoading) _boardBar(context, panelGroups),
          if (_metaFailed && _meta == null && !_metaLoading)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x1),
              child: Row(
                children: [
                  Text(
                    '榜单筛选项加载失败',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.text3,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _metaLoading = true;
                        _metaFailed = false;
                      });
                      _loadMeta();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          if (_filtersOpen && panelGroups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x2),
              child: _FilterPanel(
                groups: panelGroups,
                selected: _selected,
                onPick: _pick,
                onClear: _clearFilters,
              ),
            ),
          Expanded(child: _list(context, api, tokens)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, SourceApi api, AppTokens tokens) {
    if (_error != null && _items.isEmpty) {
      return StatePanel(
        icon: Icons.error_outline,
        title: AppStrings.errorTitle,
        body: _error!,
        action: FilledButton(
          onPressed: () => _load(reset: true),
          child: const Text(AppStrings.retry),
        ),
      );
    }
    if (_loading) return const LoadingView(skeleton: SkeletonList());
    if (_items.isEmpty) {
      return const StatePanel(
        icon: Icons.leaderboard_outlined,
        title: AppStrings.emptyTitle,
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: AppSpacing.x2, bottom: AppSpacing.x4),
      itemCount: _items.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        _prefetch(index);
        if (index >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.x4),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final item = _items[index];
        if (index == 0) {
          return _RankHero(
            item: item,
            onTap: () => _openRankItem(context, api, item),
          );
        }
        return _RankRow(
          rank: index + 1,
          item: item,
          tokens: tokens,
          onTap: () => _openRankItem(context, api, item),
        );
      },
    );
  }

  Widget _boardBar(BuildContext context, List<FilterGroup> panelGroups) {
    final meta = _meta!;
    FilterGroup? outer;
    FilterGroup? sub;
    for (final group in meta.groups) {
      if (group.key == 'outer') outer = group;
      if (group.key == 'sub') sub = group;
    }
    final outerSelected = _selected['outer'] ?? const <String>{};
    final subSelected = _selected['sub'] ?? const <String>{};
    final activeOuter = outerSelected.isNotEmpty
        ? outerSelected.first
        : (meta.defaults['outer']?.isNotEmpty == true
            ? meta.defaults['outer']!
            : (outer != null && outer.options.isNotEmpty
                ? outer.options.first.id
                : ''));
    var outerLabel = '';
    for (final option in outer?.options ?? const <FilterOption>[]) {
      if (option.id == activeOuter) {
        outerLabel = option.label;
        break;
      }
    }
    // Only the boards that belong to the selected outer type.
    final subOptions = (sub?.options ?? const <FilterOption>[])
        .where((option) =>
            option.parent.isEmpty || option.parent == activeOuter)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final option
                          in outer?.options ?? const <FilterOption>[])
                        Padding(
                          padding: const EdgeInsets.only(
                            right: AppSpacing.x6,
                          ),
                          child: UnderlineTab(
                            label: option.label,
                            selected: outerSelected.contains(option.id),
                            onTap: () => _pick(outer!, option.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (panelGroups.isNotEmpty)
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _filtersOpen = !_filtersOpen),
                  icon: Icon(
                    _filtersOpen ? Icons.close : Icons.tune,
                    size: 16,
                  ),
                  label: Text(_filtersOpen ? '收起' : '筛选'),
                ),
            ],
          ),
          if (subOptions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x1),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.x3),
                      child: Row(
                        children: [
                          Text(
                            outerLabel.isEmpty
                                ? '子榜单'
                                : '$outerLabel 榜单',
                            style: TextStyle(
                              fontSize: AppFontSize.xxs,
                              fontWeight: FontWeight.w700,
                              color: AppTokens.of(context).colors.text3,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.x3),
                          Container(
                            width: 1,
                            height: 12,
                            color: AppTokens.of(context)
                                .colors
                                .border
                                .withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                    for (final option in subOptions)
                      Padding(
                        padding:
                            const EdgeInsets.only(right: AppSpacing.x4),
                        child: UnderlineTab(
                          label: option.label,
                          selected: subSelected.contains(option.id),
                          onTap: () => _pick(sub!, option.id),
                          compact: true,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _clearFilters() {
    setState(() {
      _selected.removeWhere(
        (key, _) => key != 'outer' && key != 'sub',
      );
    });
    _load(reset: true);
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.groups,
    required this.selected,
    required this.onPick,
    required this.onClear,
  });

  final List<FilterGroup> groups;
  final Map<String, Set<String>> selected;
  final void Function(FilterGroup group, String value) onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x3,
        AppSpacing.x1,
      ),
      decoration: BoxDecoration(
        color: tokens.colors.surface2.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.colors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 230),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.x2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 68,
                      child: Text(
                        group.title,
                        style: TextStyle(
                          fontSize: AppFontSize.xxs,
                          color: tokens.colors.text3,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: AppSpacing.x3,
                        runSpacing: AppSpacing.x1,
                        children: [
                          for (final option in group.options)
                            FilterText(
                              label: option.label,
                              selected: (selected[group.key] ??
                                      const <String>{})
                                  .contains(option.id),
                              onTap: () => onPick(group, option.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onClear,
                child: const Text('清空筛选'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The #1 work as a cinematic cover card: blurred cover, sharp poster, a large
/// ghosted rank numeral and a dark scrim for readable white type.
class _RankHero extends StatefulWidget {
  const _RankHero({required this.item, required this.onTap});

  final Item item;
  final VoidCallback onTap;

  @override
  State<_RankHero> createState() => _RankHeroState();
}

class _RankHeroState extends State<_RankHero> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final item = widget.item;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppDuration.micro,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: _hovered
                  ? (Theme.of(context).brightness == Brightness.dark
                      ? AppShadows.dark
                      : AppShadows.light)
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: SizedBox(
                height: 220,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverImage(
                      url: item.cover,
                      seed: item.title,
                      fit: BoxFit.cover,
                      decodeWidth: 400,
                      blurSigma: 18,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.black.withValues(alpha: 0.22),
                            Colors.black.withValues(alpha: 0.88),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: AppSpacing.x3,
                      top: -10,
                      child: Text(
                        '01',
                        style: TextStyle(
                          fontSize: 104,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.x3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: 110,
                            height: 150,
                            child: CoverImage(
                              url: item.cover,
                              seed: item.title,
                              decodeWidth: 400,
                              radius: AppRadius.sm,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.x3),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '榜首',
                                  style: TextStyle(
                                    fontSize: AppFontSize.xs,
                                    fontWeight: FontWeight.w700,
                                    color: tokens.colors.badgeGold,
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.x1),
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    height: 1.2,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    shadows: [
                                      Shadow(
                                        color: Color(0x99000000),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                                if (_rankMeta(item).isNotEmpty) ...[
                                  const SizedBox(height: AppSpacing.x1),
                                  Text(
                                    _rankMeta(item),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppFontSize.xs,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                                if (item.badges.isNotEmpty) ...[
                                  const SizedBox(height: AppSpacing.x2),
                                  AppBadgeRow(
                                    labels: item.badges,
                                    onImage: true,
                                    compact: true,
                                    max: 2,
                                  ),
                                ],
                                const SizedBox(height: AppSpacing.x2),
                                const Text(
                                  '点击查看榜单详情',
                                  style: TextStyle(
                                    fontSize: AppFontSize.xxs,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
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
        ),
      ),
    );
  }
}

class _RankRow extends StatefulWidget {
  const _RankRow({
    required this.rank,
    required this.item,
    required this.tokens,
    required this.onTap,
  });

  final int rank;
  final Item item;
  final AppTokens tokens;
  final VoidCallback onTap;

  @override
  State<_RankRow> createState() => _RankRowState();
}

class _RankRowState extends State<_RankRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x1,
            vertical: AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            color: _hovered
                ? tokens.colors.surface2.withValues(alpha: 0.55)
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: tokens.colors.border.withValues(alpha: 0.65),
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  '${widget.rank}',
                  style: TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w800,
                    color: widget.rank <= 3
                        ? tokens.colors.accent
                        : tokens.colors.text3,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                height: 58,
                child: CoverImage(
                  url: widget.item.cover,
                  seed: widget.item.title,
                  radius: AppRadius.sm,
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppFontSize.bodyLg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_rankMeta(widget.item).isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _rankMeta(widget.item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.xxs,
                          color: tokens.colors.text3,
                        ),
                      ),
                    ],
                    if (widget.item.badges.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.x1),
                      AppBadgeRow(
                        labels: widget.item.badges,
                        compact: true,
                        max: 2,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The source's category followed by the work's genre tags, so a rank row
/// explains why a title is ranked without opening it.
String _rankMeta(Item item, {int maxTags = 3}) {
  final kind = str(item.extra['category']);
  final tags = item.tags.take(maxTags).where((tag) => tag.isNotEmpty);
  return [
    if (kind.isNotEmpty) kind,
    ...tags,
  ].join(' · ');
}
