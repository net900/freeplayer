import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../settings/settings.dart';
import '../sp/emoji.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/editorial.dart';
import 'login_sheet.dart';

/// 弹幕列表 + 发送 + 点赞. Danmaku needs the logged-in account; the sheet
/// offers a login action instead of failing silently.
Future<void> showDanmakuSheet(
  BuildContext context, {
  required SourceApi api,
  required String itemId,
  required String episodeId,
  required int positionSec,
  required int durationSec,
  required List<DanmakuLine> lines,
  required VoidCallback onChanged,
  required void Function(DanmakuLine line) onSent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.of(context).colors.surface,
    builder: (sheetContext) => DanmakuSheet(
      api: api,
      itemId: itemId,
      episodeId: episodeId,
      positionSec: positionSec,
      durationSec: durationSec,
      initial: lines,
      onChanged: onChanged,
      onSent: onSent,
    ),
  );
}

class DanmakuSheet extends StatefulWidget {
  const DanmakuSheet({
    super.key,
    required this.api,
    required this.itemId,
    required this.episodeId,
    required this.positionSec,
  required this.durationSec,
    required this.initial,
    required this.onChanged,
    required this.onSent,
  });

  final SourceApi api;
  final String itemId;
  final String episodeId;
  final int positionSec;
  final int durationSec;
  final List<DanmakuLine> initial;
  final VoidCallback onChanged;
  final void Function(DanmakuLine line) onSent;

  @override
  State<DanmakuSheet> createState() => _DanmakuSheetState();
}

class _DanmakuSheetState extends State<DanmakuSheet> {
  final TextEditingController _input = TextEditingController();
  late List<DanmakuLine> _lines;
  bool _loading = true;
  bool _sending = false;
  String? _notice;
  String? _error;
  bool _needsLogin = false;
  int _tab = 0;
  // Sent danmaku are queued for review upstream: add() returns an id but the
  // list does not contain it yet. Keep our own copy so the send is visible.
  final List<DanmakuLine> _pending = [];

  @override
  void initState() {
    super.initState();
    _lines = [...widget.initial];
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.danmaku(
        itemId: widget.itemId,
        episodeId: widget.episodeId,
        offsetSec: widget.positionSec,
        // The upstream returns an empty packet when the duration is 0; a
        // default window length still yields the current 30s slice.
        durationSec: widget.durationSec > 0 ? widget.durationSec : 180,
      );
      if (!mounted) return;
      setState(() {
        final ids = page.items.map((line) => line.id).toSet();
        _lines = [
          ...page.items,
          ..._pending.where((line) => !ids.contains(line.id)),
        ];
        _loading = false;
        _needsLogin = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeGatewayError(error);
        _needsLogin =
            error is SpException && error.code == SpErrorCode.unauthorized;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final id = await widget.api.sendDanmaku(
        itemId: widget.itemId,
        episodeId: widget.episodeId,
        text: text,
        offsetSec: widget.positionSec,
      );
      if (!mounted) return;
      final local = DanmakuLine(
        id: id,
        time: widget.positionSec.toDouble(),
        text: text,
        userName: '我',
      );
      _input.clear();
      setState(() {
        _sending = false;
        _notice = '已发送，审核通过后所有人可见';
        _pending.insert(0, local);
        _lines = [local, ..._lines];
      });
      widget.onSent(local);
      widget.onChanged();
      await _load();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = describeGatewayError(error);
        _needsLogin =
            error is SpException && error.code == SpErrorCode.unauthorized;
      });
    }
  }

  Future<void> _login() async {
    final ok = await showLoginSheet(context, api: widget.api);
    if (!mounted || !ok) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.62,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x4,
                  AppSpacing.x3,
                  AppSpacing.x2,
                  AppSpacing.x1,
                ),
                child: Row(
                  children: [
                    Text(
                      '弹幕',
                      style: TextStyle(
                        color: tokens.colors.text,
                        fontSize: AppFontSize.title,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Text(
                      '${_lines.length}',
                      style: TextStyle(
                        color: tokens.colors.text3,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close, color: tokens.colors.text2),
                    ),
                  ],
                ),
              ),
              UnderlineTabBar(
                labels: const ['弹幕列表', '显示设置'],
                selected: _tab,
                compact: true,
                onPick: (value) => setState(() => _tab = value),
              ),
              if (_tab == 0 && _needsLogin)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '登录后可查看和发送弹幕',
                          style: TextStyle(
                            color: tokens.colors.text2,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      FilledButton(
                        onPressed: _login,
                        child: const Text('登录'),
                      ),
                    ],
                  ),
                ),
              if (_tab == 0 && _error != null && !_needsLogin)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                  child: Text(
                    _error!,
                    style: TextStyle(color: tokens.colors.accent, fontSize: 12),
                  ),
                ),
              Expanded(
                child: _tab == 0
                    ? _body(tokens)
                    // The sliders write settings; without a listener the
                    // readouts and thumb positions never refresh.
                    : ListenableBuilder(
                        listenable: AppScope.controllerOf(context),
                        builder: (context, _) => _settings(tokens),
                      ),
              ),
              if (_tab == 0) _composer(tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppTokens tokens) {
    if (_loading && _lines.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lines.isEmpty) {
      return Center(
        child: Text(
          _needsLogin ? '登录后显示弹幕' : '这一集还没有弹幕',
          style: TextStyle(color: tokens.colors.text3),
        ),
      );
    }
    final sorted = [..._lines]..sort((a, b) => a.time.compareTo(b.time));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: tokens.colors.border,
      ),
      itemBuilder: (context, index) {
        final line = sorted[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  _format(line.time),
                  style: TextStyle(
                    color: tokens.colors.text3,
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  renderEmoji(line.text),
                  style: TextStyle(color: tokens.colors.text, height: 1.4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _settings(AppTokens tokens) {
    final controller = AppScope.controllerOf(context);
    final settings = controller.settings;
    void save(AppSettings next) {
      controller.updateSettings(next);
    }

    Widget slider({
      required String label,
      required String value,
      required double min,
      required double max,
      required double current,
      required ValueChanged<double> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4,
          vertical: AppSpacing.x2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppFontSize.body,
                    color: tokens.colors.text,
                  ),
                ),
                const Spacer(),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    color: tokens.colors.text3,
                  ),
                ),
              ],
            ),
            Slider(
              value: current.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: AppSpacing.x2),
      children: [
        slider(
          label: '字体大小',
          value: '${settings.danmakuFontSize.round()}',
          min: 12,
          max: 28,
          current: settings.danmakuFontSize,
          onChanged: (value) => save(
            settings.copyWith(danmakuFontSize: value.roundToDouble()),
          ),
        ),
        slider(
          label: '不透明度',
          value: '${(settings.danmakuOpacity * 100).round()}%',
          min: 0.25,
          max: 1,
          current: settings.danmakuOpacity,
          onChanged: (value) =>
              save(settings.copyWith(danmakuOpacity: value)),
        ),
        slider(
          label: '弹幕速度',
          value: '${settings.danmakuSpeed.toStringAsFixed(1)}x',
          min: 0.5,
          max: 2.5,
          current: settings.danmakuSpeed,
          onChanged: (value) => save(settings.copyWith(danmakuSpeed: value)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x4,
            AppSpacing.x2,
            AppSpacing.x4,
            0,
          ),
          child: Text(
            '设置会立即应用到画面，并记住到下次播放。',
            style: TextStyle(
              fontSize: AppFontSize.xxs,
              color: tokens.colors.text3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _composer(AppTokens tokens) {
    final body = Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x3,
        AppSpacing.x3,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: tokens.colors.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              style: TextStyle(color: tokens.colors.text),
              maxLength: 60,
              decoration: InputDecoration(
                counterText: '',
                hintText: '在 ${_format(widget.positionSec.toDouble())} 发一条弹幕…',
                hintStyle: TextStyle(color: tokens.colors.text3),
                filled: true,
                fillColor: tokens.colors.surface2,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x2,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('发送'),
          ),
        ],
      ),
    );
    if (_notice == null) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.x1),
          child: Text(
            _notice!,
            style: TextStyle(fontSize: AppFontSize.xxs, color: tokens.colors.text3),
          ),
        ),
        body,
      ],
    );
  }

  static String _format(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
