import '../../app/app_config.dart';
import '../../app/app_controller.dart';
import '../../core/gateway/recommended_sources.dart';
import '../../core/local_source/local_sources_service.dart';

class RecommendedSourceResult {
  const RecommendedSourceResult({
    required this.name,
    required this.local,
  });

  final String name;
  final bool local;
}

/// Adds one recommendation through the normal gateway/install path. The
/// source itself still supplies its name, menu and capabilities.
Future<RecommendedSourceResult> addRecommendedSource({
  required RecommendedSource item,
  required AppController controller,
  required LocalSourcesService localSources,
}) async {
  if (item.isLocal) {
    final source = await localSources.install(item, controller);
    return RecommendedSourceResult(name: source.name, local: true);
  }
  // Hongguo ships as the embedded core: install that first instead of
  // requiring the remote gateway. Fall back to the address if it fails.
  if (item.sourceId == coreSourceId) {
    final source = await controller.installCoreSource();
    if (source != null) {
      return RecommendedSourceResult(name: source.name, local: false);
    }
  }
  final added = await controller.addRecommendedGateway(
    url: item.url,
    name: item.name,
    sourceId: item.sourceId,
  );
  if (added == null) {
    throw StateError('连上了地址，但没有读到可用的源。');
  }
  return RecommendedSourceResult(name: item.name, local: false);
}
