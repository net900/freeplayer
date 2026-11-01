import 'package:flutter/material.dart';

import '../../app/app_config.dart';
import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../core/decryptor/decryptor_registry.dart';
import '../../core/pages/common.dart';
import '../../core/local/external_links.dart';
import '../../core/pages/loading.dart';
import '../../core/settings/settings.dart';
import '../../core/sp/quality.dart';
import '../../core/update/update_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../l10n/strings.dart';
import '../update/update_dialog.dart';

/// Player preferences only. The source (and its account) belongs to the
/// source page: it changes with the active source, so it cannot live in
/// app-wide settings.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _association = false;
  bool _didInit = false;
  Future<List<DecryptorEntry>>? _decryptors;
  bool _checkingUpdate = false;
  String? _updateStatus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _loadAssociation();
    _decryptors = AppScope.of(context).decryptorRegistry.scan();
  }

  Future<void> _loadAssociation() async {
    try {
      final value = await AppScope.of(context).fileAssociation.isRegistered();
      if (mounted) setState(() => _association = value);
    } on Object {
      // A failed query simply leaves the switch off.
    }
  }

  Future<void> _checkUpdate(AppController controller) async {
    setState(() {
      _checkingUpdate = true;
      _updateStatus = null;
    });
    final result = await UpdateService.check(
      declinedKey: controller.settings.updateDeclinedKey,
    );
    if (!mounted) return;
    final info = result.info;
    setState(() {
      _checkingUpdate = false;
      _updateStatus = result.failed
          ? '检查失败，请稍后再试'
          : info == null
              ? '已是最新版本'
              : '发现新版本 ${info.version}';
    });
    if (info != null) {
      await showUpdateDialog(context, info, onDecline: () {
        controller.updateSettings(
          controller.settings.copyWith(updateDeclinedKey: info.declineKey),
        );
      });
    }
  }

  void _scanDecryptors() {
    setState(() {
      _decryptors = AppScope.of(context).decryptorRegistry.scan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final controller = scope.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildSettings(context, scope, controller),
    );
  }

  Widget _buildSettings(
    BuildContext context,
    AppScope scope,
    AppController controller,
  ) {
    final settings = controller.settings;
    final tokens = AppTokens.of(context);

    return ContentFrame(
      scrollable: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: AppStrings.settings),
          const SizedBox(height: AppSpacing.x4),
          _Section(
            title: AppStrings.theme,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x2,
                ),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(AppStrings.settingsThemeSystem),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(AppStrings.settingsThemeLight),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(AppStrings.settingsThemeDark),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (selection) => _update(
                    controller,
                    settings.copyWith(themeMode: selection.first),
                  ),
                ),
              ),
            ],
          ),
          _Section(
            title: AppStrings.play,
            children: [
              _SettingRow(
                label: AppStrings.settingsQuality,
                subtitle: AppStrings.qualityAuto,
                trailing: _QualityDropdown(
                  value: settings.defaultQuality,
                  onChanged: (value) => _update(
                    controller,
                    settings.copyWith(defaultQuality: value),
                  ),
                ),
              ),
              _SwitchRow(
                label: AppStrings.settingsAutoNext,
                value: settings.autoPlayNext,
                onChanged: (value) => _update(
                  controller,
                  settings.copyWith(autoPlayNext: value),
                ),
              ),
              _SwitchRow(
                label: AppStrings.settingsProgress,
                value: settings.rememberProgress,
                onChanged: (value) => _update(
                  controller,
                  settings.copyWith(rememberProgress: value),
                ),
              ),
              _SettingRow(
                label: '预加载数量',
                subtitle: '当前内容之后预先缓冲的剧/集数，越大切换越快',
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: settings.preloadAhead,
                    dropdownColor: tokens.colors.surface2,
                    items: [
                      for (var value = 1; value <= 4; value++)
                        DropdownMenuItem(
                          value: value,
                          child: Text('$value 部/集'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _update(
                        controller,
                        settings.copyWith(preloadAhead: value),
                      );
                    },
                  ),
                ),
              ),
              _SettingRow(
                label: AppStrings.settingsPlayerKernel,
                subtitle: AppStrings.kernelAuto,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<PlayerKernel>(
                    value: settings.playerKernel,
                    dropdownColor: tokens.colors.surface2,
                    items: const [
                      DropdownMenuItem(
                        value: PlayerKernel.auto,
                        child: Text(AppStrings.kernelAuto),
                      ),
                      DropdownMenuItem(
                        value: PlayerKernel.system,
                        child: Text(AppStrings.kernelSystem),
                      ),
                      DropdownMenuItem(
                        value: PlayerKernel.builtin,
                        child: Text(AppStrings.kernelBuiltin),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _update(
                        controller,
                        settings.copyWith(playerKernel: value),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          _Section(
            title: AppStrings.download,
            children: [
              _SettingRow(
                label: AppStrings.settingsDownloadQuality,
                subtitle: AppStrings.qualityAuto,
                trailing: _QualityDropdown(
                  value: settings.downloadQuality,
                  onChanged: (value) => _update(
                    controller,
                    settings.copyWith(downloadQuality: value),
                  ),
                ),
              ),
              _SettingRow(
                label: AppStrings.settingsConcurrency,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: settings.maxConcurrentDownloads,
                    dropdownColor: tokens.colors.surface2,
                    items: [
                      for (var value = 1; value <= 5; value++)
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _update(
                        controller,
                        settings.copyWith(maxConcurrentDownloads: value),
                      );
                    },
                  ),
                ),
              ),
              _SettingRow(
                label: AppStrings.settingsSegments,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: settings.downloadSegments,
                    dropdownColor: tokens.colors.surface2,
                    items: [
                      for (final value in const [1, 2, 4, 6, 8, 10, 12])
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _update(
                        controller,
                        settings.copyWith(downloadSegments: value),
                      );
                    },
                  ),
                ),
              ),
              _SettingRow(
                label: AppStrings.settingsQuota,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: settings.offlineQuotaGB,
                    dropdownColor: tokens.colors.surface2,
                    items: [
                      for (final value in const [5, 10, 20, 50, 100, 200])
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _update(
                        controller,
                        settings.copyWith(offlineQuotaGB: value),
                      );
                    },
                  ),
                ),
              ),
              _SettingRow(
                label: AppStrings.settingsDownloadDir,
                subtitle: settings.downloadDirectory,
                trailing: TextButton(
                  onPressed: () => _editDownloadDirectory(
                    controller,
                    settings.downloadDirectory,
                  ),
                  child: const Text(AppStrings.settingsEdit),
                ),
              ),
            ],
          ),
          _Section(
            title: '存储',
            children: [
              _SettingRow(
                label: '清理缓存',
                subtitle:
                    '图片缓存 ${_mb(PaintingBinding.instance.imageCache.currentSizeBytes)}',
                trailing: TextButton(
                  onPressed: _clearCache,
                  child: const Text('清理'),
                ),
              ),
              _SettingRow(
                label: '清空下载目录',
                subtitle: () {
                  final manager = AppScope.of(context).downloads;
                  final count = manager.records.length;
                  return count == 0
                      ? '还没有已下载的视频'
                      : '$count 个文件 · ${_mb(manager.totalBytes)}';
                }(),
                trailing: TextButton(
                  onPressed: () => _clearDownloads(context),
                  child: const Text('清空'),
                ),
              ),
            ],
          ),
          _Section(
            title: AppStrings.settingsFileAssoc,
            children: [
              _SwitchRow(
                label: AppStrings.settingsFileAssoc,
                subtitle: AppStrings.fileAssocNote,
                value: _association,
                onChanged: (value) => _toggleAssociation(scope, value),
              ),
              _SettingRow(
                label: '',
                subtitle: null,
                trailing: TextButton(
                  onPressed: () => scope.fileAssociation.openSystemDefaultApps(),
                  child: const Text(AppStrings.openSystemSettings),
                ),
              ),
            ],
          ),
          _Section(
            title: '关于',
            children: [
              _SettingRow(
                label: '官方网站',
                subtitle: projectWebsite,
                trailing: TextButton(
                  onPressed: () => openExternalUrl(projectWebsite),
                  child: const Text('打开'),
                ),
              ),
              _SettingRow(
                label: '开源仓库',
                subtitle: 'github.com/net900/freeplayer',
                trailing: TextButton(
                  onPressed: () => openExternalUrl(projectRepository),
                  child: const Text('打开'),
                ),
              ),
            ],
          ),
          _Section(
            title: '版本与更新',
            children: [
              _SettingRow(
                label: '当前版本',
                subtitle: '$appVersion · $updateChannelLabel',
                trailing: TextButton(
                  onPressed:
                      _checkingUpdate ? null : () => _checkUpdate(controller),
                  child: Text(_checkingUpdate ? '检查中…' : '检查更新'),
                ),
              ),
              if (_updateStatus != null)
                _SettingRow(label: '', subtitle: _updateStatus, trailing: null),
            ],
          ),
          _Section(
            title: AppStrings.settingsDecryptors,
            children: [
              _SettingRow(
                label: AppStrings.settingsDecryptorDir,
                subtitle: scope.decryptorRegistry.directory.path,
                trailing: TextButton(
                  onPressed: _scanDecryptors,
                  child: const Text(AppStrings.settingsRefresh),
                ),
              ),
              _decryptorList(context, tokens),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          Text(
            '版本 $appVersion · $updateChannelLabel',
            style: TextStyle(
              fontSize: AppFontSize.xxs,
              color: tokens.colors.text3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _decryptorList(BuildContext context, AppTokens tokens) {
    final future = _decryptors;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<DecryptorEntry>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.x3),
            child: Column(
              children: [
                LoadingLine(compact: true),
                SizedBox(height: AppSpacing.x2),
                SkeletonBox(height: 32),
              ],
            ),
          );
        }
        final entries = snapshot.data ?? const <DecryptorEntry>[];
        if (entries.isEmpty) {
          return _SettingRow(
            label: AppStrings.settingsNoDecryptors,
            subtitle: null,
          );
        }
        return Column(
          children: [
            for (final entry in entries)
              _SettingRow(
                label: entry.id,
                subtitle: entry.path,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.colors.surface3,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    entry.kind.name,
                    style: TextStyle(
                      fontSize: AppFontSize.xxs,
                      color: tokens.colors.text2,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _toggleAssociation(AppScope scope, bool value) async {
    try {
      if (value) {
        await scope.fileAssociation.register();
      } else {
        await scope.fileAssociation.unregister();
      }
      if (!mounted) return;
      setState(() => _association = value);
      _snack(value
          ? AppStrings.fileAssocRegistered
          : AppStrings.fileAssocUnregistered);
    } on Object catch (error) {
      if (!mounted) return;
      _snack('${AppStrings.fileAssocFailed}: $error');
    }
  }

  Future<void> _editDownloadDirectory(
    AppController controller,
    String current,
  ) async {
    final textController = TextEditingController(text: current);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.settingsDownloadDir),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'D:\\Videos'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(textController.text),
            child: const Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    textController.dispose();
    if (value == null || value.trim().isEmpty) return;
    await controller.updateSettings(
      controller.settings.copyWith(downloadDirectory: value.trim()),
    );
  }

  void _update(AppController controller, AppSettings next) {
    controller.updateSettings(next);
  }

  String _mb(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }

  void _clearCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    _snack('已清理图片缓存');
  }

  Future<void> _clearDownloads(BuildContext context) async {
    final manager = AppScope.of(context).downloads;
    final count = manager.records.length;
    if (count == 0) {
      _snack('没有可清理的下载');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空下载目录'),
        content: Text('删除 $count 个已下载视频及其记录？文件会被永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await manager.clearAll(deleteFiles: true);
    if (mounted) _snack('已清空下载目录');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.x1,
              bottom: AppSpacing.x2,
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: AppFontSize.xs,
                fontWeight: FontWeight.w600,
                color: tokens.colors.text2,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: tokens.colors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: tokens.colors.border),
            ),
            child: Column(
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0)
                    Divider(height: 1, color: tokens.colors.border),
                  children[index],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    this.subtitle,
    this.trailing,
  });

  final String label;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: const TextStyle(fontSize: AppFontSize.body),
                  ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: AppFontSize.xxs,
                        height: 1.5,
                        color: tokens.colors.text3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      label: label,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _QualityDropdown extends StatelessWidget {
  const _QualityDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: Quality.options.contains(value) ? value : Quality.auto,
        dropdownColor: tokens.colors.surface2,
        items: [
          for (final option in Quality.options)
            DropdownMenuItem(
              value: option,
              child: Text(
                option == Quality.auto ? AppStrings.qualityAuto : option,
              ),
            ),
        ],
        onChanged: (selected) {
          if (selected != null) onChanged(selected);
        },
      ),
    );
  }
}
