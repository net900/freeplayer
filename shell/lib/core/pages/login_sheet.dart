import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../gateway/gateway_errors.dart';
import '../gateway/source_api.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Login for the gateway account: QR scan or SMS code. The session stays in
/// the gateway; the shell only displays the QR image and submits the code.
Future<bool> showLoginSheet(BuildContext context, {required SourceApi api}) async {
  final labels =
      AppScope.controllerOf(context).uiManifest?.labels ?? const <String, String>{};
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.of(context).colors.surface,
    builder: (sheetContext) => LoginSheet(api: api, labels: labels),
  );
  return done ?? false;
}

enum _LoginMode { qr, sms }

class LoginSheet extends StatefulWidget {
  const LoginSheet({
    super.key,
    required this.api,
    this.labels = const {},
  });

  final SourceApi api;

  /// Source-supplied copy. Empty keys fall back to neutral wording; the shell
  /// never mentions a specific product or app.
  final Map<String, String> labels;

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _LoginMode _mode = _LoginMode.qr;
  LoginQr? _qr;
  Uint8List? _qrBytes;
  String _status = 'new';
  String _message = '';
  bool _loading = true;
  bool _done = false;
  bool _sendingCode = false;
  bool _smsBusy = false;
  int _countdown = 0;
  bool _appHint = false;
  String? _error;
  Timer? _poll;
  Timer? _countdownTimer;
  int _attempts = 0;
  final Map<String, TextEditingController> _custom = {};
  bool _customBusy = false;

  SourceLoginFlow? get _flow => widget.api.manifest.auth?.login;

  bool get _isCustom {
    final flow = _flow;
    return flow != null && flow.fields.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    final flow = _flow;
    if (flow != null && flow.fields.isNotEmpty) {
      for (final field in flow.fields) {
        _custom[field.key] = TextEditingController();
      }
      _loading = false;
      _message = flow.description;
    } else {
      _start();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _countdownTimer?.cancel();
    _phone.dispose();
    _code.dispose();
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _label(String key, String fallback) {
    final value = widget.labels[key] ?? '';
    return value.isEmpty ? fallback : value;
  }

  Future<void> _start() async {
    _poll?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _qr = null;
      _qrBytes = null;
      _status = 'new';
      _message = _label('login.message', '请登录');
    });
    try {
      final qr = await widget.api.loginQrCode();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _qrBytes = _decodeQr(qr.image);
        _loading = false;
        _status = 'new';
        _message = _label('login.message', '请登录');
      });
      _poll = Timer.periodic(const Duration(milliseconds: 2100), (_) => _check());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeGatewayError(error);
      });
    }
  }

  Future<void> _check() async {
    final qr = _qr;
    if (qr == null || _done) return;
    _attempts++;
    if (qr.expireAt > 0 &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 > qr.expireAt) {
      _poll?.cancel();
      if (mounted) {
        setState(() {
          _status = 'expired';
          _message = '二维码已过期，请点击刷新二维码';
        });
      }
      return;
    }
    try {
      final status = await widget.api.loginQrStatus(qr.token);
      if (!mounted || _done) return;
      switch (status.status) {
        case 'scanned':
          setState(() => _message = _label('login.scanned', '已扫码，请在手机上确认'));
        case 'confirmed':
          _finish(_label('login.confirmed', '登录成功'));
        case 'expired':
          _poll?.cancel();
          setState(() {
            _status = 'expired';
            _message = _label('login.expired', '二维码已过期，请点击刷新二维码');
          });
        default:
          // 'new' is the steady state: do not rebuild the sheet (and the
          // Image.memory inside it) every poll tick.
          if (status.status != _status) {
            setState(() {
              _status = status.status;
              if (status.description.isNotEmpty) _message = status.description;
            });
          }
      }
    } on Object {
      if (_attempts % 5 == 0 && mounted) {
        setState(() => _message = _label('login.waiting', '等待登录…'));
      }
    }
  }

  void _finish(String message) {
    _done = true;
    _poll?.cancel();
    _countdownTimer?.cancel();
    setState(() {
      _status = 'confirmed';
      _message = message;
      _error = null;
    });
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  Future<void> _sendCode() async {
    final mobile = _phone.text.trim();
    if (mobile.length != 11 || _sendingCode || _countdown > 0) return;
    setState(() {
      _sendingCode = true;
      _error = null;
      _appHint = false;
    });
    try {
      final data = await widget.api.sendSmsCode(mobile);
      if (!mounted) return;
      final retry = int.tryParse('${data['retry_time'] ?? 60}') ?? 60;
      setState(() {
        _sendingCode = false;
        _countdown = retry > 0 ? retry : 60;
        _message = _label('login.code_sent', '验证码已发送');
      });
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _countdown--);
        if (_countdown <= 0) timer.cancel();
      });
    } on Object catch (error) {
      if (!mounted) return;
      final limited =
          error is SpException && error.code == SpErrorCode.rateLimited;
      setState(() {
        _sendingCode = false;
        _appHint = limited;
        _error = limited ? null : describeGatewayError(error);
        if (limited) {
          _message = _label('login.message_limited', '请稍后重试');
        }
      });
    }
  }

  Future<void> _smsLogin() async {
    final mobile = _phone.text.trim();
    final code = _code.text.trim();
    if (mobile.length != 11 || code.isEmpty || _smsBusy) return;
    setState(() {
      _smsBusy = true;
      _error = null;
    });
    try {
      await widget.api.smsLogin(mobile: mobile, code: code);
      if (!mounted) return;
      _finish(_label('login.confirmed', '登录成功'));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _smsBusy = false;
        _error = describeGatewayError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.x6,
          right: AppSpacing.x6,
          top: AppSpacing.x4,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.x4,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    (_flow?.title.isNotEmpty ?? false)
                        ? _flow!.title
                        : _label('login.title', '登录账号'),
                    style: TextStyle(
                      color: tokens.colors.text,
                      fontSize: AppFontSize.title,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(_done),
                    icon: Icon(Icons.close, color: tokens.colors.text3),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x2),
              if (_isCustom) ...[
                _customBody(tokens),
              ] else ...[
                _modeSwitch(tokens),
                const SizedBox(height: AppSpacing.x3),
                if (_mode == _LoginMode.qr)
                  _qrBody(tokens)
                else
                  _smsBody(tokens),
              ],
              if (_message.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x3),
                Text(
                  _message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _status == 'confirmed'
                        ? tokens.colors.accent
                        : tokens.colors.text2,
                    height: 1.4,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.x2),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFE8453C),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _customBody(AppTokens tokens) {
    final flow = _flow!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in flow.fields) ...[
          TextField(
            controller: _custom[field.key],
            obscureText: field.type == 'password',
            keyboardType: field.type == 'tel'
                ? TextInputType.phone
                : field.type == 'email'
                    ? TextInputType.emailAddress
                    : TextInputType.text,
            maxLines: field.type == 'textarea' ? 3 : 1,
            style: TextStyle(color: tokens.colors.text),
            decoration: _decoration(
              field.label.isEmpty ? field.key : field.label,
              tokens,
            ).copyWith(
              hintText: field.placeholder.isEmpty ? null : field.placeholder,
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
        ],
        const SizedBox(height: AppSpacing.x2),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: _done || _customBusy ? null : _submitCustom,
            child: _customBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(flow.submitLabel.isEmpty
                    ? _label('login.action', '登录')
                    : flow.submitLabel),
          ),
        ),
      ],
    );
  }

  Future<void> _submitCustom() async {
    final flow = _flow;
    if (flow == null) return;
    final values = <String, String>{};
    for (final field in flow.fields) {
      final value = _custom[field.key]?.text.trim() ?? '';
      if (field.required && value.isEmpty) {
        final name = field.label.isEmpty ? field.key : field.label;
        setState(() {
          _error = _label('login.required', '必填项不能为空')
              .replaceAll('{field}', name);
        });
        return;
      }
      values[field.key] = value;
    }
    setState(() {
      _customBusy = true;
      _error = null;
    });
    try {
      final result = await widget.api.loginWith(
        flow.method.isEmpty ? 'form' : flow.method,
        values,
      );
      if (!mounted) return;
      final name = '${result['name'] ?? result['user_name'] ?? ''}';
      _finish(name.isEmpty
          ? _label('login.confirmed', '登录成功')
          : '${_label('login.confirmed', '登录成功')} · $name');
      AppScope.controllerOf(context).refreshLogin();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _customBusy = false);
    }
  }

  Widget _modeSwitch(AppTokens tokens) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final entry in [
          (_LoginMode.qr, _label('login.qr_tab', '扫码登录')),
          (_LoginMode.sms, _label('login.sms_tab', '短信验证登录')),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
            child: InkWell(
              onTap: _done
                  ? null
                  : () => setState(() {
                        _mode = entry.$1;
                        _error = null;
                        _message = entry.$1 == _LoginMode.qr
                            ? (_status == 'expired'
                                ? _label('login.expired',
                                    '二维码已过期，请点击刷新二维码')
                                : _label('login.message', '请登录'))
                            : _label('login.sms_hint', '输入手机号获取验证码');
                      }),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x4,
                  vertical: AppSpacing.x2,
                ),
                decoration: BoxDecoration(
                  color: _mode == entry.$1
                      ? tokens.colors.accentWeak
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(
                    color: _mode == entry.$1
                        ? tokens.colors.accent
                        : tokens.colors.border,
                  ),
                ),
                child: Text(
                  entry.$2,
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    color: _mode == entry.$1
                        ? tokens.colors.accent
                        : tokens.colors.text2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _qrBody(AppTokens tokens) {
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        if (_qrBytes != null)
          _QrImage(bytes: _qrBytes!)
        else
          SizedBox(
            height: 160,
            child: Icon(Icons.qr_code_2, size: 96, color: tokens.colors.text3),
          ),
        const SizedBox(height: AppSpacing.x3),
        OutlinedButton.icon(
          onPressed: _done ? null : _start,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.colors.text2,
            side: BorderSide(color: tokens.colors.border),
          ),
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(_label('login.refresh_qr', '刷新二维码')),
        ),
      ],
    );
  }

  Widget _smsBody(AppTokens tokens) {
    return Column(
      children: [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ],
          style: TextStyle(color: tokens.colors.text),
          decoration: _decoration(_label('login.phone', '手机号'), tokens),
        ),
        const SizedBox(height: AppSpacing.x2),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                style: TextStyle(color: tokens.colors.text),
                decoration: _decoration(_label('login.code', '验证码'), tokens),
                onSubmitted: (_) => _smsLogin(),
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: _countdown > 0 || _sendingCode ? null : _sendCode,
                style: OutlinedButton.styleFrom(
                  foregroundColor: tokens.colors.text2,
                  side: BorderSide(color: tokens.colors.border),
                ),
                child: Text(
                  _countdown > 0
                      ? '${_countdown}s'
                      : (_sendingCode
                          ? _label('login.sending', '发送中…')
                          : _label('login.send_code', '发送验证码')),
                ),
              ),
            ),
          ],
        ),
        if (_appHint) ...[
          const SizedBox(height: AppSpacing.x3),
          _appHintBox(tokens),
        ],
        const SizedBox(height: AppSpacing.x4),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton(
            onPressed: _done || _smsBusy ? null : _smsLogin,
            child: _smsBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_label('login.action', '登录')),
          ),
        ),
      ],
    );
  }

  Widget _appHintBox(AppTokens tokens) {
    final steps = _label('login.steps', '')
        .split('\n')
        .where((step) => step.trim().isNotEmpty)
        .toList(growable: false);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: tokens.colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _label('login.error_limited', '验证码获取过于频繁，请稍后重试'),
            style: TextStyle(
              color: tokens.colors.text,
              fontSize: AppFontSize.xs,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (steps.isNotEmpty) const SizedBox(height: AppSpacing.x2),
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x1),
              child: Text(
                step,
                style: TextStyle(
                  color: tokens.colors.text2,
                  fontSize: AppFontSize.xs,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String hint, AppTokens tokens) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: tokens.colors.text3),
      filled: true,
      fillColor: tokens.colors.surface2,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x3,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _QrImage extends StatelessWidget {
  const _QrImage({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Image.memory(
        bytes,
        width: 220,
        height: 220,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.none,
      ),
    );
  }
}

Uint8List? _decodeQr(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  final payload = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
  try {
    return base64Decode(payload);
  } on Object {
    return null;
  }
}
