import 'package:flutter/material.dart';

/// Address-only dialog. The source name and description are never typed here:
/// they are read from the address when it answers.
Future<String?> showSourceUrlDialog(
  BuildContext context, {
  required String title,
  String initialUrl = '',
  String confirmLabel = '连接',
  String hintText = 'https://example.com',
  String helperText = '名称和介绍会从地址读取',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SourceUrlDialog(
      title: title,
      initialUrl: initialUrl,
      confirmLabel: confirmLabel,
      hintText: hintText,
      helperText: helperText,
    ),
  );
}

class _SourceUrlDialog extends StatefulWidget {
  const _SourceUrlDialog({
    required this.title,
    required this.initialUrl,
    required this.confirmLabel,
    required this.hintText,
    required this.helperText,
  });

  final String title;
  final String initialUrl;
  final String confirmLabel;
  final String hintText;
  final String helperText;

  @override
  State<_SourceUrlDialog> createState() => _SourceUrlDialogState();
}

class _SourceUrlDialogState extends State<_SourceUrlDialog> {
  // Owned by the dialog state so it outlives the closing animation: the
  // previous whenComplete(dispose) ran while the TextField was still rebuilding.
  late final TextEditingController _url =
      TextEditingController(text: widget.initialUrl);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    Navigator.of(context).pop(_url.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _url,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '地址',
            hintText: widget.hintText,
            helperText: widget.helperText,
          ),
          onSubmitted: (_) => _submit(context),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _submit(context),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
