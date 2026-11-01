import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/gateway/recommended_sources.dart';
import '../../core/local_source/local_sources_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import 'recommended_source_actions.dart';
import 'recommended_source_tile.dart';

/// The website's curated list, shown inside the source page instead of a
/// separate dialog. The close button hides it and saves the preference.
class RecommendedSourcesPanel extends StatefulWidget {
  const RecommendedSourcesPanel({
    super.key,
    required this.controller,
    required this.localSources,
    required this.onClose,
  });

  final AppController controller;
  final LocalSourcesService localSources;
  final Future<void> Function() onClose;

  @override
  State<RecommendedSourcesPanel> createState() =>
      _RecommendedSourcesPanelState();
}

class _RecommendedSourcesPanelState extends State<RecommendedSourcesPanel> {
  List<RecommendedSource> _items = const [];
  bool _loading = true;
  String? _error;
  String? _addingId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_addingId != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await RecommendedSourcesApi.fetch();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _add(RecommendedSource item) async {
    if (_addingId != null) return;
    setState(() {
      _addingId = item.id;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await addRecommendedSource(
        item: item,
        controller: widget.controller,
        localSources: widget.localSources,
      );
      if (!mounted) return;
      setState(() => _addingId = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.local ? '已安装本地源「${result.name}」' : '已添加「${result.name}」',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _addingId = null;
        _error = _messageOf(error);
      });
    }
  }

  String _localKey(RecommendedSource item) =>
      item.sourceId.isNotEmpty ? item.sourceId : item.id;

  bool _added(RecommendedSource item) {
    if (item.isLocal) {
      return widget.localSources.isInstalled(_localKey(item));
    }
    // The embedded core serves Hongguo under its own gateway, not the
    // recommended URL, so the source id is the reliable match.
    if (item.sourceId.isNotEmpty &&
        widget.controller.enabledSources
            .any((source) => source.sourceId == item.sourceId)) {
      return true;
    }
    final target = normalizeSourceUrl(item.url);
    for (final gateway in widget.controller.gateways) {
      if (normalizeSourceUrl(gateway.baseUrl) == target) return true;
    }
    return false;
  }

  String _messageOf(Object error) {
    if (error is RecommendedSourcesException) return error.message;
    final text = error.toString();
    return text.isEmpty ? '拉取推荐源失败。' : text;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x4,
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x4,
      ),
      decoration: BoxDecoration(
        color: tokens.colors.surface2.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: tokens.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_outlined,
                size: 18,
                color: tokens.colors.accent,
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                '官方推荐源',
                style: TextStyle(
                  fontSize: AppFontSize.title,
                  fontWeight: FontWeight.w700,
                  color: tokens.colors.text,
                ),
              ),
              const Spacer(),
              if (!_loading && _items.isNotEmpty)
                Text(
                  '${_items.length} 个',
                  style: TextStyle(
                    fontSize: AppFontSize.xxs,
                    color: tokens.colors.text3,
                  ),
                ),
              IconButton(
                tooltip: '刷新推荐源',
                onPressed: _addingId == null ? _load : null,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 32, height: 32),
                icon: Icon(
                  Icons.refresh,
                  size: 18,
                  color: tokens.colors.text3,
                ),
              ),
              IconButton(
                tooltip: '关闭推荐源',
                onPressed: _addingId == null ? () => widget.onClose() : null,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 32, height: 32),
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: tokens.colors.text3,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.x2),
            child: Text(
              '站点整理的源，内容由源提供者维护。添加后仍由源自己提供名称和菜单。',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                height: 1.55,
                color: tokens.colors.text3,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => _body(tokens),
          ),
        ],
      ),
    );
  }

  Widget _body(AppTokens tokens) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x4),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tokens.colors.accent,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '正在拉取推荐源…',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                color: tokens.colors.text3,
              ),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error ?? '暂时没有推荐源。可以在官网后台添加。',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                height: 1.55,
                color:
                    _error == null ? tokens.colors.text3 : tokens.colors.danger,
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            TextButton(
              onPressed: _load,
              child: const Text('重新拉取'),
            ),
          ],
        ),
      );
    }

    final hasError = _error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 720 ? 2 : 1;
            final width =
                (constraints.maxWidth - AppSpacing.x4 * (columns - 1)) /
                    columns;
            return Wrap(
              spacing: AppSpacing.x4,
              runSpacing: AppSpacing.x2,
              children: [
                for (final item in _items)
                  SizedBox(
                    width: width,
                    child: RecommendedSourceTile(
                      source: item,
                      added: _added(item),
                      updateAvailable: _updateAvailable(item),
                      busy: _addingId == item.id,
                      disabled: _addingId != null,
                      onAdd: () => _add(item),
                    ),
                  ),
              ],
            );
          },
        ),
        if (hasError) ...[
          const SizedBox(height: AppSpacing.x2),
          Text(
            _error!,
            style: TextStyle(
              fontSize: AppFontSize.xs,
              height: 1.5,
              color: tokens.colors.danger,
            ),
          ),
        ],
      ],
    );
  }

  bool _updateAvailable(RecommendedSource item) {
    if (!item.isLocal) return false;
    final key = _localKey(item);
    final installedVersion = widget.localSources.installedVersion(key);
    final installedSha = widget.localSources.installedSha(key);
    final versionChanged = item.packageVersion.isNotEmpty &&
        installedVersion.isNotEmpty &&
        installedVersion != item.packageVersion;
    final contentChanged = item.packageSha256.isNotEmpty &&
        installedSha.isNotEmpty &&
        installedSha != item.packageSha256;
    return versionChanged || contentChanged;
  }
}
