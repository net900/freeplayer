import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/local_source/local_sources_service.dart';
import 'source_dialog.dart';

/// One address field for every source. A URL whose path ends in `.js` is
/// installed as a local script source; everything else is a gateway address.
/// Returns true when a source was added (and, for local scripts, selected).
Future<bool> showAddSourceFlow(
  BuildContext context, {
  required AppController controller,
  required LocalSourcesService localSources,
  required Future<bool> Function(String url) onAddNetwork,
}) async {
  final url = await showSourceUrlDialog(
    context,
    title: '添加源',
    confirmLabel: '添加',
    hintText: 'https://example.com',
    helperText: '填写网关地址；以 .js 结尾的地址会作为本地源安装。',
  );
  if (url == null || url.isEmpty || !context.mounted) return false;

  final uri = Uri.tryParse(url);
  if (uri != null && uri.path.toLowerCase().endsWith('.js')) {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final source = await localSources.installFromUrl(url, controller);
      messenger.showSnackBar(
        SnackBar(content: Text('已安装本地源「${source.name}」')),
      );
      return true;
    } on Object catch (error) {
      final text = error.toString();
      messenger.showSnackBar(
        SnackBar(content: Text(text.isEmpty ? '安装本地源失败。' : text)),
      );
      return false;
    }
  }

  return onAddNetwork(url);
}
