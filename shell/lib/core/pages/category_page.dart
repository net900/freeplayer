import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'loading.dart';
import 'navigation.dart';
import 'poster_card.dart';
import '../widgets/editorial.dart';
import '../widgets/hero_carousel.dart';

/// 分类: the landpage selector rows (体裁 / 主题 / 设定 / 背景 / 排序 / 受众 / 上新时间).
class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key, required this.ctx});

  final PageContext ctx;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  final Map<String, Set<String>> _selected = {};
  final List<Item> _items = [];
  final ScrollController _scroll = ScrollController();
  List<FilterGroup> _groups = const [];
  String _next = '';
  bool _metaLoading = true;
  bool _metaFailed = false;
  bool _initialTagsApplied = false;
  bool _started = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _epoch = 0;

  /// Channel/category id carried by the navigation item (`params.tags`).
  /// Passed to the source as `tag`, so 电影/剧集/综艺… load different lists.
  String _tag = '';

  /// Wide editorial cards supplied by the source for the home page.
  List<Item> _hero = const [];

  @override
  void didUpdateWidget(covariant CategoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = (widget.ctx.params['tags'] ?? '').trim();
    if (next == _tag) return;
    _tag = next;
    _selected.clear();
    _load(reset: true);
    _loadMeta();
    _loadHero();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _tag = (widget.ctx.params['tags'] ?? '').trim();
    // Content first: the filter panel can arrive (or fail) independently.
    _load(reset: true);
    _loadMeta();
    _loadHero();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillIfNeeded());
  }

  /// A short first page can leave the grid unscrollable, which would stop the
  /// waterfall before page 2. Pull one more page while there is nothing to
  /// scroll.
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

  SourceApi? get _api => AppScope.controllerOf(context).sourceApi;

  Future<void> _loadMeta() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _metaLoading = true;
      _metaFailed = false;
    });
    // The selector endpoint is the flakiest upstream request; retry once
    // before showing a retry affordance.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final groups = await api.categoryMeta(tag: _tag);
        if (!mounted) return;
        setState(() {
          _groups = groups;
          _metaLoading = false;
          _metaFailed = groups.isEmpty;
        });
        _applyInitialTags();
        return;
      } on Object {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _metaLoading = false;
      _metaFailed = true;
    });
  }

  Future<void> _loadHero() async {
    final api = _api;
    if (api == null) return;
    if (_tag.isNotEmpty) {
      if (_hero.isNotEmpty) setState(() => _hero = const []);
      return;
    }
    try {
      final items = await api.hero();
      if (!mounted || items.isEmpty) return;
      setState(() => _hero = items);
    } on Object {
      // A source without a banner feed simply keeps the fallback cards.
    }
  }

  /// Detail-page category chips pass human labels ("爱情"), not selector ids.
  /// Resolve them against the cloud panel so the filter is a real id.
  void _applyInitialTags() {
    if (_initialTagsApplied) return;
    _initialTagsApplied = true;
    final raw = widget.ctx.params['tags'] ?? '';
    final labels = raw
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (labels.isEmpty) return;
    var matched = false;
    for (final label in labels) {
      for (final group in _groups) {
        for (final option in group.options) {
          if (option.label != label) continue;
          final active = _selected.putIfAbsent(group.key, () => <String>{});
          if (!group.multi) active.clear();
          active.add(option.id);
          matched = true;
          break;
        }
      }
    }
    if (matched) {
      // The label resolved into a selector id; do not also send it as a
      // channel tag.
      _tag = '';
      _load(reset: true);
    }
  }

  String _join(String key) => (_selected[key] ?? const <String>{}).join(',');

  Future<void> _load({bool reset = false}) async {
    final api = _api;
    if (api == null) return;
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
      final page = await api.category(
        tag: _tag,
        genre: _join('genre'),
        theme: _join('category_dim_theme'),
        role: _join('category_dim_role'),
        epoch: _join('category_dim_epoch'),
        sort: _join('sort'),
        gender: _join('gender'),
        onlineTime: _join('online_time'),
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
        _error = describeGatewayError(error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _toggle(FilterGroup group, FilterOption option) {
    final active = _selected[group.key] ?? <String>{};
    setState(() {
      if (group.multi) {
        if (active.contains(option.id)) {
          active.remove(option.id);
        } else {
          active.add(option.id);
        }
      } else {
        active
          ..clear()
          ..add(option.id);
      }
      _selected[group.key] = active;
    });
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    if (api == null) {
      return const StatePanel(
        icon: Icons.category_outlined,
        title: AppStrings.emptyTitle,
        body: AppStrings.emptyBody,
      );
    }
    final content = _content(api);
    // A source without filter metadata (or one whose selector endpoint is
    // down) has nothing to put in the rail. Showing an empty "筛选" panel and
    // a load-failure note on the home page is worse than showing none.
    if (!_metaLoading && _groups.isEmpty) {
      return ContentFrame(child: content);
    }
    final rail = _FilterRail(
      groups: _groups,
      selected: _selected,
      loading: _metaLoading,
      failed: _metaFailed,
      onToggle: _toggle,
      onRetry: _loadMeta,
      onClear: _clearFilters,
    );
    return ContentFrame(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              children: [
                SizedBox(height: 220, child: rail),
                const SizedBox(height: AppSpacing.x3),
                Expanded(child: content),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 224, child: rail),
              const SizedBox(width: AppSpacing.x6),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  void _clearFilters() {
    setState(() => _selected.clear());
    _load(reset: true);
  }

  Widget _content(SourceApi api) {
    if (_loading) return const LoadingView(skeleton: SkeletonGrid());
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
    if (_items.isEmpty) {
      return StatePanel(
        icon: Icons.category_outlined,
        title: AppStrings.emptyTitle,
        body: _selected.isEmpty
            ? null
            : '当前筛选组合可能过窄，减少一个条件再试试。',
        action: _selected.isEmpty
            ? null
            : OutlinedButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                label: const Text('清空筛选'),
              ),
      );
    }
    final feedHero = _hero.isNotEmpty;
    final showHero = !_metaLoading &&
        _groups.isEmpty &&
        _tag.isEmpty &&
        (feedHero || _items.length > 3);
    final heroItems = showHero
        ? (feedHero ? _hero : _items.take(4).toList(growable: false))
        : const <Item>[];
    final gridItems = showHero && !feedHero
        ? _items.skip(heroItems.length).toList(growable: false)
        : _items;

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (heroItems.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x6),
              child: HeroCarousel(
                items: heroItems,
                onTap: (item) => openDetail(context, api, item),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.x1),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: AppSpacing.x4,
              crossAxisSpacing: AppSpacing.x4,
              childAspectRatio: AppSizes.posterAspect,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                _prefetch(index);
                if (index >= gridItems.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                final item = gridItems[index];
                return PosterCard(
                  item: item,
                  onTap: () => openDetail(context, api, item),
                );
              },
              childCount: gridItems.length + (_loadingMore ? 1 : 0),
            ),
          ),
        ),
      ],
    );
  }
}

/// Left catalogue rail: every cloud filter dimension as text options. No
/// rounded chip wall and no fixed-height panel with empty space.
class _FilterRail extends StatelessWidget {
  const _FilterRail({
    required this.groups,
    required this.selected,
    required this.loading,
    required this.failed,
    required this.onToggle,
    required this.onRetry,
    required this.onClear,
  });

  final List<FilterGroup> groups;
  final Map<String, Set<String>> selected;
  final bool loading;
  final bool failed;
  final void Function(FilterGroup group, FilterOption option) onToggle;
  final VoidCallback onRetry;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: AppSpacing.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            title: '筛选',
            trailing: TextButton(
              onPressed: onClear,
              child: const Text('清空'),
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.x2),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (!loading && failed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x2),
              child: Row(
                children: [
                  Text(
                    '筛选项加载失败',
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: tokens.colors.text3,
                    ),
                  ),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          for (final group in groups) ...[
            const SizedBox(height: AppSpacing.x3),
            Text(
              group.title,
              style: TextStyle(
                fontSize: AppFontSize.xxs,
                fontWeight: FontWeight.w600,
                color: tokens.colors.text3,
              ),
            ),
            const SizedBox(height: AppSpacing.x1),
            Wrap(
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x1,
              children: [
                for (final option in group.options)
                  FilterText(
                    label: option.label,
                    selected:
                        (selected[group.key] ?? const <String>{})
                            .contains(option.id),
                    onTap: () => onToggle(group, option),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
