import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'login_sheet.dart';

enum _AccountAction { logout, switchAccount }

/// Left-rail account entry: logs in when signed out, otherwise shows the
/// profile with 退出登录 / 切换账号.
Future<void> showAccountDialog(
  BuildContext context,
  AppController controller,
) async {
  final api = controller.sourceApi;
  if (api == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('还没有连接内容源。请先添加内容源。')),
    );
    return;
  }

  await controller.refreshLogin();
  if (!context.mounted) return;
  var user = controller.account;

  if (user == null) {
    if (!await showLoginSheet(context, api: api)) return;
    await controller.refreshLogin();
    if (!context.mounted) return;
    user = controller.account;
  }
  final current = user;
  if (current == null) return;

  final action = await showDialog<_AccountAction>(
    context: context,
    builder: (dialogContext) => _ProfileDialog(user: current),
  );
  if (action == null) return;

  if (action == _AccountAction.logout) {
    await api.logout();
    await controller.refreshLogin();
    return;
  }

  await api.logout();
  await controller.refreshLogin();
  if (!context.mounted) return;
  if (await showLoginSheet(context, api: api)) {
    await controller.refreshLogin();
  }
}

class _ProfileDialog extends StatelessWidget {
  const _ProfileDialog({required this.user});

  final AccountUser user;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final avatar = user.avatar;
    final name = user.userName;
    final id = user.userId;
    return AlertDialog(
      title: const Text('账号'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: tokens.colors.surface3,
            backgroundImage: avatar.isEmpty ? null : NetworkImage(avatar),
            child: avatar.isEmpty
                ? Icon(Icons.person, color: tokens.colors.text3)
                : null,
          ),
          const SizedBox(width: AppSpacing.x3),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '已登录' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: AppFontSize.bodyLg),
                ),
                if (id.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'ID $id',
                      style: TextStyle(
                        fontSize: AppFontSize.xxs,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_AccountAction.logout),
          child: const Text('退出登录'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_AccountAction.switchAccount),
          child: const Text('切换账号'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
