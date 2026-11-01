import 'package:flutter/widgets.dart';

import '../sp/page_types.dart';

/// Everything a built-in page needs to render without knowing a source.
@immutable
class PageContext {
  const PageContext({
    this.sourceId = '',
    this.itemId = '',
    this.params = const {},
    this.data = const {},
  });

  final String sourceId;
  final String itemId;
  final Map<String, String> params;
  final Map<String, Object?> data;

  PageContext copyWith({
    String? sourceId,
    String? itemId,
    Map<String, String>? params,
    Map<String, Object?>? data,
  }) {
    return PageContext(
      sourceId: sourceId ?? this.sourceId,
      itemId: itemId ?? this.itemId,
      params: params ?? this.params,
      data: data ?? this.data,
    );
  }
}

typedef AppPageBuilder = Widget Function(BuildContext context, PageContext ctx);

/// Maps the closed set of page types to widgets. Sources only choose a type;
/// they cannot supply widgets or code (PRD §6.6).
class PageRegistry {
  PageRegistry();

  final Map<String, AppPageBuilder> _builders = {};

  void register(String type, AppPageBuilder builder) {
    if (!PageTypes.isKnown(type)) {
      throw ArgumentError.value(type, 'type', 'not a registered page type');
    }
    _builders[type] = builder;
  }

  AppPageBuilder? builderFor(String type) => _builders[type];

  Widget? build(String type, BuildContext context, PageContext ctx) {
    final builder = _builders[type];
    if (builder == null) {
      debugPrint('page type "$type" is unknown; item hidden (PRD §5.5)');
      return null;
    }
    return KeyedSubtree(key: ValueKey(type), child: builder(context, ctx));
  }

  bool supports(String type) => _builders.containsKey(type);

  List<String> get registeredTypes => _builders.keys.toList(growable: false);
}
