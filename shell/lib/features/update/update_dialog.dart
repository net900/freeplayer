import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/update/update_info.dart';
import '../../core/update/update_service.dart';

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  required VoidCallback onDecline,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => UpdateDialog(info: info, onDecline: onDecline),
  );
}

enum _Phase { prompt, downloading, installing, error }

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.info, required this.onDecline});

  final UpdateInfo info;
  final VoidCallback onDecline;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  _Phase _phase = _Phase.prompt;
  int _received = 0;
  int _total = 0;
  String _message = '';

  UpdateInfo get _info => widget.info;

  /// Beta builds and non-replace releases are installed by the user from the
  /// website; only stable `replace` builds update in place.
  bool get _manualOnly =>
      UpdateService.isBeta || !_info.hasArchive || _info.mode != 'replace';

  void _decline() {
    widget.onDecline();
    Navigator.of(context).pop();
  }

  Future<void> _start() async {
    if (_manualOnly) {
      await UpdateService.openManual(_info);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = _info.size;
    });
    try {
      final stage = await UpdateService.prepare(
        _info,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.installing);
      await UpdateService.launch(stage);
      // update.exe waits for this pid, replaces the files and restarts us.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      exit(0);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = error is UpdateException
            ? error.message
            : '更新失败，可到官网手动下载';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return AlertDialog(
      title: Text('发现新版本 ${_info.version}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (_info.channelLabel.isNotEmpty) _info.channelLabel,
                if (_info.date.isNotEmpty) _info.date,
                if (_info.size > 0) _sizeLabel(_info.size),
              ].join(' · '),
              style: TextStyle(fontSize: AppFontSize.xs, color: tokens.colors.text3),
            ),
            if (_info.title.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.x2),
              Text(
                _info.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (_info.notes.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.x2),
              for (final note in _info.notes.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('· $note'),
                ),
            ],
            if (_phase == _Phase.downloading) ...[
              const SizedBox(height: AppSpacing.x4),
              LinearProgressIndicator(
                value: _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null,
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(_progressLabel()),
            ],
            if (_phase == _Phase.installing) ...[
              const SizedBox(height: AppSpacing.x4),
              const LinearProgressIndicator(),
              const SizedBox(height: AppSpacing.x2),
              const Text('正在安装，程序即将自动重启…'),
            ],
            if (_phase == _Phase.error) ...[
              const SizedBox(height: AppSpacing.x4),
              Text(_message, style: TextStyle(color: tokens.colors.danger)),
              const SizedBox(height: AppSpacing.x2),
              const Text('可以到官网手动下载最新版本。'),
            ],
          ],
        ),
      ),
      actions: _actions(context),
    );
  }

  List<Widget> _actions(BuildContext context) {
    switch (_phase) {
      case _Phase.prompt:
        return [
          TextButton(onPressed: _decline, child: const Text('稍后再说')),
          FilledButton(
            onPressed: _start,
            child: Text(_manualOnly ? '前往下载' : '下载更新'),
          ),
        ];
      case _Phase.downloading:
      case _Phase.installing:
        return const [];
      case _Phase.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => UpdateService.openManual(_info),
            child: const Text('前往官网下载'),
          ),
        ];
    }
  }

  String _progressLabel() {
    if (_total <= 0) return '正在下载 ${_sizeLabel(_received)}';
    final percent = (_received * 100 / _total).clamp(0, 100).toStringAsFixed(0);
    return '正在下载 $percent%  (${_sizeLabel(_received)} / ${_sizeLabel(_total)})';
  }

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
