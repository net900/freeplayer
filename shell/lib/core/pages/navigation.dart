import 'package:flutter/material.dart';

import '../gateway/source_api.dart';
import '../renderer/page_registry.dart';
import '../sp/models.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'route.dart';

/// Opens a detail route inside the current (nested) navigator so the sidebar
/// stays in place. Completes when the detail page is popped.
Future<void> openDetail(
  BuildContext context,
  SourceApi api,
  Item item, {
  String poster = '',
}) {
  return Navigator.of(context).push(
    instantRoute(
      (_) => OpaquePage(
        child: DetailContent(item: item, api: api, poster: poster),
      ),
    ),
  );
}

/// Opens 分类 with labels preselected (a detail-page category chip). The page
/// resolves labels to the cloud's real selector ids once its panel loads.
Future<void> openCategory(
  BuildContext context,
  SourceApi api, {
  List<String> tags = const [],
}) {
  return Navigator.of(context).push(
    instantRoute(
      (_) => OpaquePage(
        child: CategoryPage(
          ctx: PageContext(
            sourceId: api.sourceId,
            params: {if (tags.isNotEmpty) 'tags': tags.join(',')},
          ),
        ),
      ),
    ),
  );
}
