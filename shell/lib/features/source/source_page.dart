import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../core/gateway/gateway_errors.dart';
import '../../core/gateway/models.dart';
import '../../core/local_source/local_sources_service.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/glass.dart';
import '../../l10n/strings.dart';
import 'recommended_sources_panel.dart';
import 'source_add_sheet.dart';
import 'source_chooser.dart';
import 'source_dialog.dart';

/// The switch page. Same shelf as the first screen; choosing a row enters
/// that source right away and closes the page.
class SourcePage extends StatefulWidget {
  const SourcePage({super.key});

  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controllerOf(context);
    final localSources = AppScope.of(context).localSources;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sources = controller.enabledSources
            .where((source) => source.manifest != null)
            .toList(growable: false);
        return Scaffold(
          body: AtmosphereBackground(
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.x2,
                      AppSpacing.x2,
                      AppSpacing.x6,
                      0,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: AppStrings.backToPrevious,
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.x8,
                        AppSpacing.x2,
                        AppSpacing.x8,
                        AppSpacing.x8,
                      ),
                      child: SourceChooser(
                        title: AppStrings.switchSource,
                        subtitle: sources.isEmpty
                            ? (controller.showRecommendedSources
                                ? '还没有添加源。可以从下面的官方推荐源里选一个。'
                                : '还没有添加源。点「添加源」填写地址。')
                            : '已添加 ${sources.length} 个源。点一下进入，也可以继续添加。',
                        sources: sources,
                        recommended: controller.showRecommendedSources
                            ? RecommendedSourcesPanel(
                                key: const ValueKey('recommended-sources'),
                                controller: controller,
                                localSources: localSources,
                                onClose: () =>
                                    controller.setShowRecommendedSources(false),
                              )
                            : null,
                        onShowRecommended: () =>
                            controller.setShowRecommendedSources(true),
                        activeSourceId: controller.localMode
                            ? ''
                            : controller.activeSourceId,
                        localActive: controller.localMode,
                        status: controller.coreDownload != null
                            ? controller.coreDownload!.label
                            : controller.corePending && sources.isEmpty
                                ? '正在启动解密网关…'
                                : null,
                        busy: _busy,
                        error: _error,
                        onSelect: (source) => _select(controller, source),
                        onOpenLocalFiles: () => _local(controller),
                        onAdd: () => _add(controller, localSources),
                        onEdit: (source) => _edit(controller, source),
                        onDelete: (source) => _delete(controller, source),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _select(
    AppController controller,
    DiscoveredSource source,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await controller.selectSource(source);
      await _popPage();
    } on Object catch (error) {
      if (mounted) setState(() => _error = describeGatewayError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A closing popup menu can still be the top route. Popping this page with
  /// a bool while that route is on top makes the menu route receive the bool
  /// and throw. Wait until this page is current again, then pop it.
  Future<void> _popPage() async {
    final route = ModalRoute.of(context);
    if (route == null) {
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    for (var attempt = 0;
        attempt < 12 && mounted && !route.isCurrent;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (mounted && route.isCurrent) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _local(AppController controller) async {
    await controller.enableLocalMode();
    await _popPage();
  }

  Future<void> _add(
    AppController controller,
    LocalSourcesService localSources,
  ) async {
    final added = await showAddSourceFlow(
      context,
      controller: controller,
      localSources: localSources,
      onAddNetwork: (url) => _addNetwork(controller, url),
    );
    if (added && mounted) await _popPage();
  }

  Future<bool> _addNetwork(AppController controller, String url) async {
    if (!mounted) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final manifests = await controller.addGateway(url);
      if (manifests.isEmpty) {
        if (mounted) setState(() => _error = '这个地址没有提供可用的源。');
        return false;
      }
      await controller.selectSourceById(manifests.first.id);
      return true;
    } on Object catch (error) {
      if (mounted) setState(() => _error = describeGatewayError(error));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(
    AppController controller,
    DiscoveredSource source,
  ) async {
    final gateway = _gatewayFor(controller, source);
    if (gateway == null) return;
    final url = await showSourceUrlDialog(
      context,
      title: '编辑地址',
      initialUrl: gateway.baseUrl,
      confirmLabel: '保存',
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await controller.updateGateway(gateway.id, rawUrl: url);
    } on Object catch (error) {
      if (mounted) setState(() => _error = describeGatewayError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(
    AppController controller,
    DiscoveredSource source,
  ) async {
    final gateway = _gatewayFor(controller, source);
    if (gateway == null) return;
    final name = source.name.isEmpty ? '该内容源' : source.name;
    final local = gateway.kind == 'local-js';
    final core = gateway.kind == 'core';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(core
            ? '删除内置源'
            : local
                ? '删除本地源'
                : '删除内容源'),
        content: Text(
          core
              ? '删除「$name」？下载到本机的核心文件也会被删除。'
              : local
                  ? '删除「$name」？下载到本机的源脚本会被移除。'
                  : '删除「$name」？这个地址下的所有内容源都会被移除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (local) {
      await AppScope.of(context)
          .localSources
          .remove(gateway.localId, controller);
    } else {
      await controller.removeGateway(gateway.id);
    }
  }

  GatewayConfig? _gatewayFor(
    AppController controller,
    DiscoveredSource source,
  ) {
    for (final gateway in controller.gateways) {
      if (gateway.id == source.gatewayId) return gateway;
    }
    return null;
  }
}
