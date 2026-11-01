import 'package:flutter/foundation.dart' show debugPrint;

import '../../app/app_config.dart';
import '../../app/app_controller.dart';
import '../gateway/recommended_sources.dart';
import 'local_sources_service.dart';

/// Result of one silent local-source update pass.
class LocalSourceUpdateResult {
  const LocalSourceUpdateResult({
    this.updated = const [],
    this.packageIds = const {},
    this.failed = false,
  });

  /// Display names of the packages that were replaced.
  final List<String> updated;

  /// Package ids of the replaced sources, so the caller can tell whether the
  /// active source changed and needs a reload.
  final Set<String> packageIds;

  /// No installed source could be checked (no stored address and the catalog
  /// was unreachable); nothing was compared.
  final bool failed;

  static const LocalSourceUpdateResult none = LocalSourceUpdateResult();
}

/// Launch-time check for every installed local JS source.
///
/// Each package is downloaded again from the address it came from and
/// compared by SHA-256, so the remote file is the source of truth: a rebuilt
/// script is picked up even when its version number did not change. The
/// website catalog is only consulted to find the address of packages installed
/// before it was recorded, and an unreachable catalog never stops the check.
///
/// Remote URL sources are not part of this: their manifest always comes from
/// the gateway, and their decryptor modules are handled by
/// [AppController.refreshUi].
Future<LocalSourceUpdateResult> autoUpdateLocalSources({
  required LocalSourcesService localSources,
  required AppController controller,
  String endpoint = recommendedSourcesEndpoint,
}) async {
  final catalog = <String, RecommendedSource>{};
  var catalogFailed = false;
  try {
    for (final item in await RecommendedSourcesApi.fetch(endpoint: endpoint)) {
      final key = item.sourceId.isNotEmpty ? item.sourceId : item.id;
      if (key.isNotEmpty) catalog[key] = item;
    }
  } on Object catch (error) {
    catalogFailed = true;
    debugPrint('local source updates: catalog failed: $error');
  }

  final updated = <String>[];
  final packageIds = <String>{};
  var checked = 0;
  var unresolved = 0;
  for (final install in localSources.installs) {
    final url = install.sourceUrl.isNotEmpty
        ? install.sourceUrl
        : catalog[install.sourceId]?.packageUrl ?? '';
    if (url.isEmpty) {
      unresolved++;
      continue;
    }
    checked++;
    final name = await localSources.refreshFromUrl(
      install.packageId,
      url,
      controller,
    );
    if (name == null) continue;
    updated.add(name);
    packageIds.add(install.packageId);
  }
  debugPrint(
    'local source updates: checked=$checked updated=${updated.length} '
    'unresolved=$unresolved',
  );
  return LocalSourceUpdateResult(
    updated: updated,
    packageIds: packageIds,
    failed: catalogFailed && checked == 0 && unresolved > 0,
  );
}
