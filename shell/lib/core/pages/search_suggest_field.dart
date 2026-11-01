import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../gateway/source_api.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The search box in the top bar. It asks the active source for the same
/// suggestions the search page shows, so typing here is not a blind box.
class SearchSuggestField extends StatefulWidget {
  const SearchSuggestField({
    super.key,
    required this.api,
    required this.onSubmit,
  });

  final SourceApi? api;
  final ValueChanged<String> onSubmit;

  @override
  State<SearchSuggestField> createState() => _SearchSuggestFieldState();
}

class _SearchSuggestFieldState extends State<SearchSuggestField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'top-search');
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();
  final Map<String, List<String>> _cache = {};

  Timer? _debounce;
  int _epoch = 0;
  List<String> _words = const [];

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) return;
      // Let a tap on the list land before the overlay goes away.
      Timer(const Duration(milliseconds: 150), () {
        if (mounted && !_focus.hasFocus) _hide();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final query = raw.trim();
    _debounce?.cancel();
    if (query.isEmpty) {
      _hide();
      return;
    }
    final cached = _cache[query];
    if (cached != null) {
      // A cached answer still supersedes whatever request is in flight.
      _epoch++;
      _update(cached);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 140), () => _load(query));
  }

  Future<void> _load(String query) async {
    final api = widget.api;
    if (api == null) return;
    final epoch = ++_epoch;
    try {
      final result = await api.suggest(query, limit: 8);
      // Latest request wins, and it must still match what is in the field.
      if (!mounted || epoch != _epoch || _controller.text.trim() != query) {
        return;
      }
      final words = result.words.take(8).toList(growable: false);
      _cache[query] = words;
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      _update(words);
    } on Object {
      if (mounted && epoch == _epoch) _hide();
    }
  }

  void _update(List<String> words) {
    if (!mounted) return;
    setState(() => _words = words);
    if (words.isEmpty) {
      if (_portal.isShowing) _portal.hide();
    } else if (!_portal.isShowing) {
      _portal.show();
    }
  }

  void _hide() {
    if (!mounted) return;
    setState(() => _words = const []);
    if (_portal.isShowing) _portal.hide();
  }

  void _submit(String value) {
    final query = value.trim();
    _hide();
    _focus.unfocus();
    if (query.isEmpty) return;
    widget.onSubmit(query);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return CompositedTransformTarget(
      link: _link,
      child: SizedBox(
        width: 240,
        height: 34,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 6),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.topRight,
              child: Material(
                color: tokens.colors.surface2,
                elevation: 8,
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: SizedBox(
                  width: 300,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.x1,
                      ),
                      itemCount: _words.length,
                      itemBuilder: (context, index) {
                        final word = _words[index];
                        return InkWell(
                          onTap: () => _submit(word),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.x3,
                              vertical: AppSpacing.x2,
                            ),
                            child: Text(
                              word,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppFontSize.xs,
                                color: tokens.colors.text,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            style: const TextStyle(fontSize: AppFontSize.xs),
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: _submit,
            decoration: const InputDecoration(
              hintText: AppStrings.searchHint,
              prefixIcon: Icon(Icons.search, size: 16),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: AppSpacing.x2,
                vertical: AppSpacing.x1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
