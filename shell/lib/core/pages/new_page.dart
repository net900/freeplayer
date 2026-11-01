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
import '../widgets/app_badge.dart';
import '../widgets/cover_image.dart';
import '../widgets/editorial.dart';
import 'poster_card.dart';

/// The new-items page has two surfaces: a recommendation list with audience
/// filters, and a release calendar with 15 selectable days.
class NewPage extends StatefulWidget {
  const NewPage({super.key, required this.ctx});

  final PageContext ctx;

  @override
  State<NewPage> createState() => _NewPageState();
}

class _NewPageState extends State<NewPage> {
  int _tab = 0;
  String _gender = '2';

  @override
  Widget build(BuildContext context) {
    final api = AppScope.controllerOf(context).sourceApi;
    if (api == null) {
      return const StatePanel(
        icon: Icons.fiber_new_outlined,
        title: AppStrings.emptyTitle,
        body: AppStrings.emptyBody,
      );
    }
    final controller = AppScope.controllerOf(context);
    final labels = controller.uiManifest?.labels ?? const <String, String>{};
    // A source without calendar data advertises no `new.tab.calendar` label;
    // showing an empty second tab only wastes a click.
    final hasCalendar =
        (labels['new.tab.calendar'] ?? '').isNotEmpty ||
            (controller.sourceApi?.manifest.capabilities.contains('calendar') ??
                false);
    final genders = [
      (labels['new.gender.all'] ?? '全部', '2'),
      (labels['new.gender.male'] ?? '男频', '1'),
      (labels['new.gender.female'] ?? '女频', '0'),
    ];
    final showGenders =
        AppScope.controllerOf(context).uiManifest?.newGenderTabs ?? true;
    return ContentFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UnderlineTabBar(
            labels: [
              labels['new.tab.recommend'] ?? '最新',
              if (hasCalendar) labels['new.tab.calendar'] ?? '日历',
            ],
            selected: hasCalendar ? _tab : 0,
            onPick: (value) => setState(() => _tab = value),
          ),
          const SizedBox(height: AppSpacing.x3),
          if (_tab == 0) ...[
            if (showGenders) ...[
              Row(
                children: [
                  for (final entry in genders) ...[
                    UnderlineTab(
                      label: entry.$1,
                      selected: _gender == entry.$2,
                      onTap: () => setState(() => _gender = entry.$2),
                      compact: true,
                    ),
                    const SizedBox(width: AppSpacing.x6),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.x2),
            ],
            Expanded(
              child: _NewList(
                key: ValueKey('new-$_gender'),
                api: api,
                gender: _gender,
              ),
            ),
          ] else
            Expanded(child: _CalendarView(api: api)),
        ],
      ),
    );
  }
}

class _CalendarView extends StatefulWidget {
  const _CalendarView({required this.api});

  final SourceApi api;

  @override
  State<_CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<_CalendarView> {
  final List<Item> _items = [];
  final ScrollController _scroll = ScrollController();
  CalendarResult? _data;
  String _date = '';
  String _next = '';
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
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

  Future<void> _load({String? date, bool reset = false}) async {
    if (!reset && (_loadingMore || _next.isEmpty)) return;
    final target = date ?? _date;
    final epoch = ++_epoch;
    setState(() {
      if (reset) {
        _items.clear();
        _next = '';
        _loading = true;
        _loadingMore = false;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final result = await widget.api.calendar(
        date: target,
        cursor: reset ? '' : _next,
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
        _items.addAll(result.items.where((item) => !seen.contains(item.id)));
        _data = result;
        _date = result.targetDate;
        _next = result.next;
        _loading = false;
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillIfNeeded());
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = error;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppScope.controllerOf(context).uiManifest?.labels ??
        const <String, String>{};
    if (_loading) return const LoadingView();
    if (_error != null) {
      return StatePanel(
        icon: Icons.error_outline,
        title: AppStrings.errorTitle,
        body: _error.toString(),
        action: FilledButton(
          onPressed: () => _load(reset: true),
          child: const Text(AppStrings.retry),
        ),
      );
    }
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final api = widget.api;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: data.dates.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.x4),
            itemBuilder: (context, index) {
              final date = data.dates[index];
              return _DateTab(
                date: date,
                today: date == data.currentDate,
                selected: date == _date,
                onTap: () => _load(date: date, reset: true),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Expanded(
          child: _items.isEmpty
              ? StatePanel(
                  icon: Icons.event_available,
                  title: labels['new.empty_day'] ?? '这一天还没有内容',
                )
              : ListView.separated(
                  controller: _scroll,
                  padding: EdgeInsets.zero,
                  itemCount: _items.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.x2),
                  itemBuilder: (context, index) {
                    _prefetch(index);
                    if (index >= _items.length) {
                      return const Padding(
                        padding: EdgeInsets.all(AppSpacing.x4),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final item = _items[index];
                    return _ReleaseRow(
                      item: item,
                      onTap: () => openDetail(context, api, item),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DateTab extends StatelessWidget {
  const _DateTab({
    required this.date,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  final String date;
  final bool today;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    var weekday = '';
    if (date.length >= 8) {
      final parsed = DateTime.tryParse(
        '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}',
      );
      if (parsed != null) {
        weekday = const ['一', '二', '三', '四', '五', '六', '日'][
            parsed.weekday - 1];
      }
    }
    final day = date.length >= 8
        ? '${date.substring(4, 6)}.${date.substring(6, 8)}'
        : date;
    final color = selected ? tokens.colors.accent : tokens.colors.text2;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.x2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              today ? '今天' : '周$weekday',
              style: TextStyle(
                fontSize: AppFontSize.xxs,
                color: selected ? color : tokens.colors.text3,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              day,
              style: TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: AppSpacing.x1),
            AnimatedContainer(
              duration: AppDuration.micro,
              height: 2,
              width: selected ? 18 : 0,
              decoration: BoxDecoration(
                color: tokens.colors.accent,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseRow extends StatefulWidget {
  const _ReleaseRow({required this.item, required this.onTap});

  final Item item;
  final VoidCallback onTap;

  @override
  State<_ReleaseRow> createState() => _ReleaseRowState();
}

class _ReleaseRowState extends State<_ReleaseRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final item = widget.item;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x2),
          decoration: BoxDecoration(
            color: _hovered
                ? tokens.colors.surface2.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border(
              bottom: BorderSide(
                color: tokens.colors.border.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                height: 70,
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppFontSize.bodyLg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.badges.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.x1),
                      AppBadgeRow(
                        labels: item.badges,
                        compact: true,
                        max: 2,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: tokens.colors.text3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The new-items grid has its own cursor: the source returns a page and a
/// `next` token, so the list keeps loading as the user scrolls.
class _NewList extends StatefulWidget {
  const _NewList({super.key, required this.api, required this.gender});

  final SourceApi api;
  final String gender;

  @override
  State<_NewList> createState() => _NewListState();
}

class _NewListState extends State<_NewList> {
  final List<Item> _items = [];
  final ScrollController _scroll = ScrollController();
  String _next = '';
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillIfNeeded());
  }

  void _prefetch(int index) {
    if (_next.isEmpty || _loadingMore || _loading) return;
    if (index < _items.length ~/ 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loadingMore || _next.isEmpty)) return;
    final epoch = ++_epoch;
    setState(() {
      if (reset) {
        _items.clear();
        _next = '';
        _error = null;
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await widget.api.newItems(
        gender: widget.gender,
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView(skeleton: SkeletonList());
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
      return const StatePanel(
        icon: Icons.fiber_new_outlined,
        title: AppStrings.emptyTitle,
      );
    }
    return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(AppSpacing.x1),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: AppSpacing.x4,
          crossAxisSpacing: AppSpacing.x4,
          childAspectRatio: AppSizes.posterAspect,
        ),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          _prefetch(index);
          if (index >= _items.length) {
            return const Center(child: CircularProgressIndicator());
          }
          final item = _items[index];
          return PosterCard(
            item: item,
            forceNewBadge: true,
            onTap: () => openDetail(context, widget.api, item),
          );
        },
    );
  }
}
