import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/strings.dart';
import '../gateway/source_api.dart';
import '../library/search_history.dart';
import '../renderer/page_registry.dart';
import '../storage/local_store.dart';
import '../storage/paths.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/cover_image.dart';
import 'common.dart';
import 'loading.dart';
import 'navigation.dart';
import 'page_title.dart';
import 'poster_card.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialQuery = '', this.ctx});

  final String initialQuery;
  final PageContext? ctx;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'search');
  Timer? _suggestDebounce;
  String _query = '';
  int _searchEpoch = 0;
  int _suggestEpoch = 0;
  int _tab = 11;
  bool _didInit = false;
  bool _suggestLoading = false;
  SuggestResult _suggestions = const SuggestResult();
  bool _showSuggestions = false;
  SearchHistory? _history;
  List<String> _recent = const [];
  final Map<String, SuggestResult> _suggestCache = {};

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _showSuggestions) {
        // Leaving the field is what turns the suggestion list into results.
        final query = _controller.text.trim();
        if (query.isNotEmpty) _search(query, force: true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    // History belongs to one source: the same box under another source shows
    // what was searched there, not a mix of everything.
    _history = SearchHistory(
      LocalStore(appDataFile('search_history.json')),
      scope: AppScope.controllerOf(context).activeSourceId,
    );
    unawaited(_loadRecent());
    final initial = widget.initialQuery.trim();
    if (initial.isNotEmpty) {
      _query = initial;
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final history = _history;
    if (history == null) return;
    try {
      final list = await history.load();
      if (mounted) setState(() => _recent = list);
    } on Object {
      // History is a convenience; the field still works without it.
    }
  }

  Future<void> _remember(String query) async {
    if (query.isEmpty) return;
    final history = _history;
    if (history == null) return;
    try {
      final list = await history.add(query);
      if (mounted) setState(() => _recent = list);
    } on Object {
      // Ignore storage errors.
    }
  }

  Future<void> _removeRecent(String query) async {
    final list = await _history?.remove(query);
    if (mounted && list != null) setState(() => _recent = list);
  }

  Future<void> _clearRecent() async {
    final list = await _history?.clear();
    if (mounted && list != null) setState(() => _recent = list);
  }

  void _onChanged(String value) {
    final query = value.trim();
    _suggestDebounce?.cancel();
    if (query.isEmpty) {
      _suggestEpoch++;
      setState(() {
        _suggestions = const SuggestResult();
        _showSuggestions = false;
        _suggestLoading = false;
        _query = '';
      });
      return;
    }
    setState(() => _showSuggestions = true);
    _suggestDebounce = Timer(const Duration(milliseconds: 140), () {
      _loadSuggestions(query);
    });
  }

  Future<void> _loadSuggestions(String query) async {
    final api = _api;
    if (api == null || query.isEmpty) return;
    final epoch = ++_suggestEpoch;
    final cached = _suggestCache[query];
    if (cached != null) {
      if (mounted && _controller.text.trim() == query) {
        setState(() {
          _suggestions = cached;
          _suggestLoading = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _suggestLoading = true);
    try {
      final result = await api.suggest(query, limit: 10);
      // Latest request wins: a slow response for "AAAA" must never replace
      // the results for "AAAAB", even if the text happens to match again.
      if (!mounted ||
          epoch != _suggestEpoch ||
          _controller.text.trim() != query) {
        return;
      }
      _suggestCache[query] = result;
      if (_suggestCache.length > 40) {
        _suggestCache.remove(_suggestCache.keys.first);
      }
      setState(() {
        _suggestions = result;
        _suggestLoading = false;
      });
    } on Object {
      if (!mounted || epoch != _suggestEpoch) return;
      setState(() => _suggestLoading = false);
    }
  }

  void _search(String query, {bool force = false}) {
    if (!mounted) return;
    if (query == _query && !force) return;
    if (force) unawaited(_remember(query));
    setState(() {
      _query = query;
      // Auto-search keeps the suggestion strip visible; only an explicit
      // submit / suggestion tap hides it.
      if (force) {
        _showSuggestions = false;
        _searchEpoch++;
      }
    });
  }

  void _pickSuggestion(String word) {
    _controller.text = word;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _search(word.trim(), force: true);
    _focusNode.unfocus();
  }

  SourceApi? get _api => AppScope.controllerOf(context).sourceApi;

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final tokens = AppTokens.of(context);
    return PageTitleBinding(
      title: _query.isEmpty ? AppStrings.search : _query,
      child: ContentFrame(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            // Tapping empty space leaves the field; the focus listener turns
            // the suggestion list into search results.
            if (_focusNode.hasFocus) _focusNode.unfocus();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onChanged,
              onSubmitted: (value) {
                _search(value.trim(), force: true);
                _focusNode.unfocus();
              },
              style: const TextStyle(fontSize: AppFontSize.bodyLg),
              decoration: InputDecoration(
                hintText: AppStrings.searchHint,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          _suggestDebounce?.cancel();
                          _suggestEpoch++;
                          setState(() {
                            _query = '';
                            _suggestions = const SuggestResult();
                            _showSuggestions = false;
                            _suggestLoading = false;
                          });
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
              ),
            ),
            if (!_showSuggestions && _query.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.x2),
              Row(
                children: [
                  for (final entry in const [
                    (11, '综合'),
                    (29, '剧集'),
                    (30, '视频'),
                  ]) ...[
                    _SearchTab(
                      label: entry.$2,
                      selected: _tab == entry.$1,
                      onTap: () => setState(() => _tab = entry.$1),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                  ],
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.x3),
            Expanded(
              child: api == null
                  ? const StatePanel(
                      icon: Icons.search_off,
                      title: AppStrings.searchEmptyTitle,
                      body: AppStrings.searchEmptyBody,
                    )
                  : _showSuggestions
                      ? _suggestionView(context, tokens)
                      : _query.isEmpty
                          ? _historyView(context, tokens)
                          : _results(context, api, tokens),
            ),
            ],
          ),
        ),
        ),
    );
  }

  /// Search history shown before the user types: tap to search, × to remove,
  /// 清空 to reset.
  Widget _historyView(BuildContext context, AppTokens tokens) {
    if (_recent.isEmpty) {
      return const StatePanel(
        icon: Icons.search,
        title: AppStrings.searchEmptyTitle,
        body: AppStrings.searchEmptyBody,
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w600,
                color: tokens.colors.text,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _clearRecent,
              icon: const Icon(Icons.delete_sweep_outlined, size: 16),
              label: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x2),
        Wrap(
          spacing: AppSpacing.x2,
          runSpacing: AppSpacing.x2,
          children: [
            for (final word in _recent)
              _HistoryChip(
                label: word,
                onTap: () => _pickSuggestion(word),
                onDelete: () => _removeRecent(word),
              ),
          ],
        ),
      ],
    );
  }

  /// While typing: keywords plus drama cards with covers. Results only appear
  /// after the field loses focus or the query is submitted.
  Widget _suggestionView(BuildContext context, AppTokens tokens) {
    final labels = AppScope.controllerOf(context).uiManifest?.labels ??
        const <String, String>{};
    final items = _suggestions.items;
    final words = _suggestions.words.take(10).toList(growable: false);
    if (items.isEmpty && words.isEmpty) {
      return Column(
        children: [
          if (_suggestLoading) const LinearProgressIndicator(minHeight: 2),
          const Expanded(
            child: StatePanel(
              icon: Icons.keyboard_return,
              title: '回车或点击空白处搜索',
              body: '输入过程中显示联想',
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (_suggestLoading)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.x2),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (words.isNotEmpty) ...[
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              for (final word in words)
                InkWell(
                  onTap: () => _pickSuggestion(word),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3,
                      vertical: AppSpacing.x1,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.colors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(color: tokens.colors.border),
                    ),
                    child: Text(
                      word,
                      style: TextStyle(
                        fontSize: AppFontSize.xs,
                        color: tokens.colors.text2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
        ],
        for (final item in items.take(10))
          InkWell(
            onTap: () => _pickSuggestion(item.title),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x1,
                vertical: AppSpacing.x2,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    height: 60,
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
                            fontSize: AppFontSize.body,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _suggestionSubtitle(
                            item,
                            labels['search.type_fallback'] ?? '内容',
                          ),
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
                  Icon(
                    Icons.north_west,
                    size: 16,
                    color: tokens.colors.text3,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _suggestionSubtitle(Item item, String fallback) {
    final parts = <String>[];
    final categories = item.extra['categories'];
    if (categories is List) {
      parts.addAll(categories.take(2).map((e) => e.toString()));
    }
    if (item.episodeCount > 0) parts.add('全${item.episodeCount}集');
    final play = item.extra['play_count'];
    if (play is num && play > 0) parts.add('${formatCount(play.toInt())}次播放');
    return parts.isEmpty ? fallback : parts.join(' · ');
  }

  Widget _results(BuildContext context, SourceApi api, AppTokens tokens) {
    if (_query.isEmpty) {
      return const StatePanel(
        icon: Icons.search,
        title: AppStrings.searchEmptyTitle,
        body: AppStrings.searchEmptyBody,
      );
    }
    return _SearchResults(
      key: ValueKey('$_query-$_searchEpoch-$_tab'),
      api: api,
      query: _query,
      tabType: _tab,
      tokens: tokens,
    );
  }
}

/// One query's result grid with its own cursor, so searching again never
/// reuses the previous list or scroll position.
class _SearchResults extends StatefulWidget {
  const _SearchResults({
    super.key,
    required this.api,
    required this.query,
    required this.tabType,
    required this.tokens,
  });

  final SourceApi api;
  final String query;
  final int tabType;
  final AppTokens tokens;

  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends State<_SearchResults> {
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
      final page = await widget.api.search(
        widget.query,
        cursor: reset ? '' : _next,
        limit: 20,
        tabType: widget.tabType,
      );
      if (!mounted || epoch != _epoch) return;
      final seen = _items.map((item) => item.id).toSet();
      setState(() {
        _items.addAll(page.items.where((item) => !seen.contains(item.id)));
        _next = page.next;
        _loading = false;
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < 500) _load();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _items.isEmpty) {
      return StatePanel(
        icon: Icons.error_outline,
        title: AppStrings.errorTitle,
        body: _error!,
        action: OutlinedButton(
          onPressed: () => _load(reset: true),
          child: const Text(AppStrings.retry),
        ),
      );
    }
    if (_items.isEmpty) {
      return StatePanel(
        icon: Icons.search_off,
        title: AppStrings.emptyTitle,
        body: '“${widget.query}” ${AppStrings.emptyBody}',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _next.isEmpty ? '${_items.length} 个结果' : '${_items.length}+ 个结果',
          style: TextStyle(
            fontSize: AppFontSize.xs,
            color: widget.tokens.colors.text3,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: GridView.builder(
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
                if (index >= _items.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                final item = _items[index];
                return PosterCard(
                  item: item,
                  onTap: () => openDetail(context, widget.api, item),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.label,
    required this.onTap,
    required this.onDelete,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: tokens.colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x3,
                AppSpacing.x1,
                AppSpacing.x1,
                AppSpacing.x1,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  color: tokens.colors.text2,
                ),
              ),
            ),
          ),
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x1),
              child: Icon(
                Icons.close,
                size: 13,
                color: tokens.colors.text3,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.x1),
        ],
      ),
    );
  }
}

class _SearchTab extends StatelessWidget {
  const _SearchTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4,
          vertical: AppSpacing.x1,
        ),
        decoration: BoxDecoration(
          color: selected ? tokens.colors.accentWeak : tokens.colors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? tokens.colors.accent : tokens.colors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.xs,
            color: selected ? tokens.colors.accent : tokens.colors.text2,
          ),
        ),
      ),
    );
  }
}
