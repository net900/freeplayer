import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/decryptor/decryptor_registry.dart';
import '../core/gateway/core_download.dart';
import '../core/gateway/gateway_client.dart';
import '../core/gateway/gateway_errors.dart';
import '../core/gateway/gateway_store.dart';
import '../core/gateway/models.dart';
import '../core/gateway/preview_source_api.dart';
import '../core/gateway/source_api.dart';
import '../core/settings/settings.dart';
import '../core/settings/settings_store.dart';
import '../core/sp/models.dart';
import '../core/sp/page_types.dart';
import '../core/theme/app_theme.dart';
import '../l10n/strings.dart';
import 'app_config.dart';

/// Owns cross-feature state: settings, gateways, the active source and its
/// cached ui_manifest. Pages never talk to a gateway directly.
class AppController extends ChangeNotifier {
  AppController({
    required SettingsStore settingsStore,
    required GatewayStore gatewayStore,
    DecryptorRegistry? decryptors,
  })  : _settingsStore = settingsStore,
        _gatewayStore = gatewayStore,
        _decryptors = decryptors;

  final SettingsStore _settingsStore;
  final GatewayStore _gatewayStore;
  final DecryptorRegistry? _decryptors;
  Future<bool> Function()? _coreInstaller;
  Future<void> Function()? _coreRemover;

  /// Installs the source core. Set by bootstrap so adding a Hongguo source
  /// downloads it, while ordinary launches only check for updates.
  void setCoreInstaller(Future<bool> Function() installer) {
    _coreInstaller = installer;
  }

  /// Removes the core DLL when its source is deleted.
  void setCoreRemover(Future<void> Function() remover) {
    _coreRemover = remover;
  }

  AppSettings _settings = AppSettings(clientId: '');
  GatewayState _gatewayState = const GatewayState();
  UIManifest? _uiManifest;
  SourceApi? _sourceApi;
  GatewayClient? _client;
  final Map<String, SourceApi> _localApis = {};
  final Map<String, UIManifest> _localUi = {};
  bool _initialized = false;
  int _sourceRevision = 0;
  bool _busy = false;
  String? _error;
  bool _preview = false;
  bool _immersive = false;
  bool _corePending = false;
  CoreDownloadState? _coreDownload;
  bool _loggedIn = false;
  AccountUser? _account;
  String? _pendingLocalPath;

  AppSettings get settings => _settings;

  GatewayState get gatewayState => _gatewayState;

  List<GatewayConfig> get gateways => _gatewayState.gateways;

  List<DiscoveredSource> get enabledSources => _gatewayState.sources
      .where((source) => source.enabled)
      .toList(growable: false);

  DiscoveredSource? get activeSource => _gatewayState.activeSource;

  UIManifest? get uiManifest => _uiManifest;

  SourceApi? get sourceApi => _sourceApi;

  bool get initialized => _initialized;

  /// Bumped by [reloadActiveSource]; pages use it to rebuild after a source
  /// package was replaced in place.
  int get sourceRevision => _sourceRevision;

  bool get busy => _busy;

  String? get error => _error;

  bool get isPreview => _preview;

  /// True while the in-process core is starting: the source screen shows a
  /// hint instead of looking empty.
  bool get corePending => _corePending;

  void setCorePending(bool value) {
    if (_corePending == value) return;
    _corePending = value;
    notifyListeners();
  }

  /// Download progress for the source core, or null when nothing is being
  /// fetched. The shell shows it above the content.
  CoreDownloadState? get coreDownload => _coreDownload;

  void setCoreDownload(CoreDownloadState? value) {
    _coreDownload = value;
    notifyListeners();
  }

  /// True while the player's fullscreen button is on: the custom title bar is
  /// hidden so the video covers the whole window.
  bool get immersive => _immersive;

  void setImmersive(bool value) {
    if (_immersive == value) return;
    _immersive = value;
    notifyListeners();
  }

  bool get localMode => _gatewayState.localMode && !_preview;

  bool get needsOnboarding =>
      _initialized &&
      !_preview &&
      !_gatewayState.localMode &&
      _sourceApi == null;

  String get activeSourceName {
    if (_preview) return AppStrings.previewMode;
    return activeSource?.name ?? AppStrings.localMode;
  }

  String get activeSourceId => activeSource?.sourceId ?? '';

  Color? get themeSeed {
    final raw = activeSource?.manifest?.brand?.theme?.seed ??
        _uiManifest?.theme?.seed ??
        '';
    return colorFromHex(raw);
  }

  String? get pendingLocalPath => _pendingLocalPath;

  bool get loggedIn => _loggedIn;

  /// Whether the source page shows the website's recommended list.
  bool get showRecommendedSources => _settings.showRecommendedSources;

  /// The logged-in profile (avatar, name, id); null when signed out.
  AccountUser? get account => _account;

  void setLoggedIn(bool value) {
    if (_loggedIn == value && (value || _account == null)) return;
    _loggedIn = value;
    if (!value) _account = null;
    notifyListeners();
  }

  /// Reads the account state so the sidebar and settings can show the user.
  Future<void> refreshLogin() async {
    final api = _sourceApi;
    if (api == null) {
      if (_loggedIn || _account != null) {
        _loggedIn = false;
        _account = null;
        notifyListeners();
      }
      return;
    }
    try {
      final user = await api.account();
      final nextAccount = user.loggedIn ? user : null;
      final changed = _loggedIn != user.loggedIn ||
          _account?.userId != nextAccount?.userId ||
          _account?.userName != nextAccount?.userName ||
          _account?.avatar != nextAccount?.avatar;
      _loggedIn = user.loggedIn;
      _account = nextAccount;
      if (changed) notifyListeners();
    } on Object {
      // Keep the previous state on a transient gateway error.
    }
  }

  Future<void> init() async {
    _settings = await _settingsStore.load();
    _gatewayState = await _gatewayStore.load();
    await _cleanupLegacySources();
    final source = _gatewayState.activeSource;
    if (!_gatewayState.localMode && source != null) {
      _activate(source);
    }
    _initialized = true;
    notifyListeners();
    if (!_gatewayState.localMode && source != null) {
      unawaited(refreshUi());
      unawaited(refreshLogin());
    }
  }

  /// Removes the pre-added 555 gateway and the bundled core's Hongguo source
  /// once. Later user-added sources with the same names are left alone.
  Future<void> _cleanupLegacySources() async {
    if (_settings.legacySourcesRemoved) return;
    bool legacy(DiscoveredSource source) =>
        source.sourceId == 'dy555' ||
        source.sourceId == 'hongguo' ||
        source.name.contains('555') ||
        source.name.contains('红果');
    final removed = _gatewayState.sources.where(legacy).toList(growable: false);
    if (removed.isNotEmpty) {
      final removedGateways = removed.map((s) => s.gatewayId).toSet();
      final keptSources = _gatewayState.sources
          .where((s) => !legacy(s))
          .toList(growable: false);
      final keptGateways = _gatewayState.gateways.where((gateway) {
        // Keep the core process so it can serve future sources; it simply
        // stops exposing Hongguo.
        if (gateway.kind == 'core') return true;
        if (!removedGateways.contains(gateway.id)) return true;
        return keptSources.any((s) => s.gatewayId == gateway.id);
      }).toList(growable: false);
      final activeRemoved = removed.any(
        (source) => source.sourceId == _gatewayState.activeSourceId,
      );
      _gatewayState = _gatewayState.copyWith(
        gateways: keptGateways,
        sources: keptSources,
        activeSourceId: activeRemoved ? '' : _gatewayState.activeSourceId,
      );
      await _gatewayStore.save(_gatewayState);
    }
    _settings = _settings.copyWith(legacySourcesRemoved: true);
    await _settingsStore.save(_settings);
  }

  /// Stable key for the gateway that ships inside the app. The port is chosen
  /// per launch (a busy 8787 must never block startup), so the address lives
  /// in [GatewayConfig.baseUrl] and never in the id.
  static const String localCoreGatewayId = 'core:local';

  /// Registers (or refreshes) the gateway that ships inside the app. Unlike
  /// addGateway this never changes local mode: local playback stays selected
  /// when the core becomes ready in the background.
  Future<void> attachLocalCore(String baseUrl) async {
    final base = _trimTrailingSlash(baseUrl);
    final client = GatewayClient(baseUrl: base, clientId: _settings.clientId);
    List<SourceManifest> manifests;
    try {
      await client.meta();
      // The core is the Hongguo source's local build, so its manifest is
      // exposed like any other source. Duplicates from the remote gateway
      // are replaced below.
      manifests = await client.sources();
    } on Object {
      return;
    } finally {
      client.close();
    }
    final coreIds = manifests.map((manifest) => manifest.id).toSet();
    // Earlier builds keyed this gateway by its address; those entries (and
    // every port they remembered) are replaced by the stable id.
    final stale = _gatewayState.gateways
        .where((g) => g.name == '本地核心' && g.id != localCoreGatewayId)
        .map((g) => g.id)
        .toSet();
    bool keep(String gatewayId) =>
        gatewayId != localCoreGatewayId && !stale.contains(gatewayId);
    final gateway = GatewayConfig(
      id: localCoreGatewayId,
      baseUrl: base,
      name: '本地核心',
      lastOkAt: DateTime.now().toIso8601String(),
      kind: 'core',
    );
    final replaced = _gatewayState.sources
        .where(
          (s) => s.gatewayId != localCoreGatewayId &&
              coreIds.contains(s.sourceId),
        )
        .toList(growable: false);
    final nextSources = [
      ..._gatewayState.sources.where(
        (s) => keep(s.gatewayId) && !coreIds.contains(s.sourceId),
      ),
      ...manifests.map(
        (manifest) => _discoveredFrom(
          localCoreGatewayId,
          manifest,
          isLocal: true,
        ),
      ),
    ];
    // Drop a gateway whose only source was replaced by the core copy, so the
    // recommendation list no longer counts it as installed.
    final usedGateways = nextSources.map((s) => s.gatewayId).toSet()
      ..add(localCoreGatewayId);
    _gatewayState = _gatewayState.copyWith(
      gateways: [
        ..._gatewayState.gateways.where(
          (g) => keep(g.id) && usedGateways.contains(g.id),
        ),
        gateway,
      ],
      sources: nextSources,
    );
    await _gatewayStore.save(_gatewayState);
    await _removeUnusedDecryptors(replaced, nextSources);
    final active = activeSource;
    if (!_gatewayState.localMode &&
        active != null &&
        active.gatewayId == localCoreGatewayId) {
      // The client was created while the core was still starting; reopen it
      // now that the API answers.
      await selectSource(active);
      return;
    }
    notifyListeners();
  }

  /// Installs the Hongguo source from the embedded core, without contacting
  /// the remote gateway first. Returns null when the core is unavailable so
  /// the caller can fall back to the recommended URL.
  Future<DiscoveredSource?> installCoreSource() async {
    final installer = _coreInstaller;
    if (installer == null) return null;
    if (!await installer()) return null;
    for (final source in _gatewayState.sources) {
      if (source.sourceId == coreSourceId) {
        await selectSource(source);
        return source;
      }
    }
    return null;
  }

  Future<List<SourceManifest>> addGateway(String rawUrl,
      {String name = ''}) async {
    final uri = _normalizeGateway(rawUrl);
    final base = _trimTrailingSlash(uri.toString());
    _setBusy(true);
    _error = null;
    final client = GatewayClient(
      baseUrl: base,
      clientId: _settings.clientId,
    );
    try {
      try {
        // Optional: a source-list endpoint entered directly may not serve it.
        await client.meta();
      } on Object {
        // The source list below is the real contract.
      }
      final manifests = await client.sources();
      final gateway = GatewayConfig(
        id: base,
        baseUrl: base,
        name: name.trim().isEmpty ? uri.host : name.trim(),
        lastOkAt: DateTime.now().toIso8601String(),
      );
      final gateways = [
        ..._gatewayState.gateways.where((g) => g.id != gateway.id),
        gateway,
      ];
      final sources = [
        ..._gatewayState.sources.where((s) => s.gatewayId != gateway.id),
        ...manifests.map((manifest) => _discoveredFrom(gateway.id, manifest)),
      ];
      _gatewayState = _gatewayState.copyWith(
        gateways: gateways,
        sources: sources,
        localMode: false,
      );
      await _gatewayStore.save(_gatewayState);
      // The embedded core is the Hongguo source's local build. Download it
      // as part of installing that source, not on every launch.
      if (manifests.any((manifest) => manifest.id == coreSourceId) &&
          _coreInstaller != null) {
        try {
          await _coreInstaller!();
        } on Object {
          // The remote source stays usable if the core cannot be installed.
        }
      }
      return manifests;
    } catch (error) {
      if (!_isStaleClient(error)) _error = _messageOf(error);
      rethrow;
    } finally {
      client.close();
      _setBusy(false);
    }
  }

  /// Adds a source from the website's curated list and enters it. The
  /// recommendation is only a gateway address; the source's own manifest
  /// still supplies its name and capabilities.
  Future<DiscoveredSource?> addRecommendedGateway({
    required String url,
    required String name,
    String sourceId = '',
  }) async {
    final manifests = await addGateway(url, name: name);
    if (manifests.isEmpty) return null;
    final base = _trimTrailingSlash(_normalizeGateway(url).toString());
    DiscoveredSource? match;
    if (sourceId.isNotEmpty) {
      for (final source in _gatewayState.sources) {
        if (source.gatewayId == base && source.sourceId == sourceId) {
          match = source;
          break;
        }
      }
    }
    if (match == null) {
      for (final source in _gatewayState.sources) {
        if (source.gatewayId == base) {
          match = source;
          break;
        }
      }
    }
    // The core may have replaced the remote copy of this source.
    if (match == null && sourceId.isNotEmpty) {
      for (final source in _gatewayState.sources) {
        if (source.sourceId == sourceId) {
          match = source;
          break;
        }
      }
    }
    if (match == null && manifests.isNotEmpty) {
      final firstId = manifests.first.id;
      for (final source in _gatewayState.sources) {
        if (source.sourceId == firstId) {
          match = source;
          break;
        }
      }
    }
    if (match != null) {
      await selectSource(match);
    }
    return match;
  }

  /// Registers a downloaded local JS source. It owns its QuickJS runtime and
  /// never starts a process or talks to a gateway.
  Future<DiscoveredSource> registerLocalSource({
    required String packageId,
    required String name,
    required SourceApi api,
    required UIManifest ui,
    required SourceManifest manifest,
    bool select = false,
  }) async {
    final gatewayId = 'local:$packageId';
    final previous = _localApis[gatewayId];
    if (previous != null &&
        !identical(previous, api) &&
        previous is ClosableSourceApi) {
      (previous as ClosableSourceApi).close();
    }
    _localApis[gatewayId] = api;
    _localUi[gatewayId] = ui;

    final gateway = GatewayConfig(
      id: gatewayId,
      baseUrl: '',
      name: name,
      kind: 'local-js',
      localId: packageId,
    );
    final source = DiscoveredSource(
      gatewayId: gatewayId,
      sourceId: manifest.id,
      name: manifest.name,
      icon: manifest.icon,
      description: manifest.description,
      capabilities: manifest.capabilities,
      requiresAuth: manifest.auth?.required ?? false,
      manifest: manifest,
      isLocal: true,
    );
    final wasActive = _gatewayState.activeSourceId == manifest.id;
    _gatewayState = _gatewayState.copyWith(
      gateways: [
        ..._gatewayState.gateways.where((item) => item.id != gatewayId),
        gateway,
      ],
      sources: [
        ..._gatewayState.sources.where((item) => item.gatewayId != gatewayId),
        source,
      ],
    );
    await _gatewayStore.save(_gatewayState);
    if (select || wasActive) {
      await selectSource(source);
    } else {
      notifyListeners();
    }
    return source;
  }

  /// Edits a gateway's display name or address. The gateway keeps its id so
  /// cached manifests and the active source stay valid.
  Future<void> updateGateway(
    String gatewayId, {
    String? name,
    String? rawUrl,
  }) async {
    final old = _gatewayFor(gatewayId);
    if (old == null) return;
    var base = old.baseUrl;
    if (rawUrl != null && rawUrl.trim().isNotEmpty) {
      base = _trimTrailingSlash(_normalizeGateway(rawUrl).toString());
    }
    _setBusy(true);
    _error = null;
    final client = GatewayClient(baseUrl: base, clientId: _settings.clientId);
    try {
      try {
        // Optional: a source-list endpoint entered directly may not serve it.
        await client.meta();
      } on Object {
        // The source list below is the real contract.
      }
      final manifests = await client.sources();
      final trimmed = (name ?? old.name).trim();
      final gateway = GatewayConfig(
        id: old.id,
        baseUrl: base,
        name: trimmed.isEmpty ? Uri.parse(base).host : trimmed,
        apiKey: old.apiKey,
        lastOkAt: DateTime.now().toIso8601String(),
        kind: old.kind,
        localId: old.localId,
      );
      final active = activeSource;
      final activeHere = active?.gatewayId == old.id;
      final sources = [
        ..._gatewayState.sources.where((s) => s.gatewayId != old.id),
        ...manifests.map((manifest) => _discoveredFrom(old.id, manifest)),
      ];
      _gatewayState = _gatewayState.copyWith(
        gateways: [
          ..._gatewayState.gateways.where((g) => g.id != old.id),
          gateway,
        ],
        sources: sources,
      );
      if (activeHere) {
        final next = sources.where(
          (s) => s.sourceId == active!.sourceId && s.enabled,
        );
        if (next.isNotEmpty) {
          _gatewayState = _gatewayState.copyWith(
            activeSourceId: next.first.sourceId,
          );
          _activate(next.first);
        } else {
          _gatewayState = _gatewayState.copyWith(activeSourceId: '');
        }
      }
      await _gatewayStore.save(_gatewayState);
      notifyListeners();
      if (activeHere && _sourceApi != null) unawaited(refreshUi());
    } catch (error) {
      if (!_isStaleClient(error)) _error = _messageOf(error);
      rethrow;
    } finally {
      client.close();
      _setBusy(false);
    }
  }

  /// Removes one gateway (and its sources). If it owned the active source,
  /// another source or local mode takes over.
  Future<void> removeGateway(String gatewayId) async {
    final old = _gatewayFor(gatewayId);
    if (old == null) return;
    final removed = _gatewayState.sources
        .where((s) => s.gatewayId == gatewayId)
        .toList(growable: false);
    final remaining = _gatewayState.sources
        .where((s) => s.gatewayId != gatewayId)
        .toList(growable: false);
    final activeHere = activeSource?.gatewayId == gatewayId;
    final localApi = _localApis.remove(gatewayId);
    _localUi.remove(gatewayId);
    _gatewayState = _gatewayState.copyWith(
      gateways: _gatewayState.gateways.where((g) => g.id != gatewayId).toList(),
      sources: remaining,
      activeSourceId: activeHere ? '' : _gatewayState.activeSourceId,
    );
    if (activeHere) {
      if (localApi != null && localApi is ClosableSourceApi) {
        (localApi as ClosableSourceApi).close();
      }
      _client?.close();
      _client = null;
      _sourceApi = null;
      _uiManifest = null;
    } else if (localApi != null && localApi is ClosableSourceApi) {
      (localApi as ClosableSourceApi).close();
    }
    await _gatewayStore.save(_gatewayState);
    await _removeUnusedDecryptors(removed, remaining);
    if (old.kind == 'core' || old.id == localCoreGatewayId) {
      try {
        await _coreRemover?.call();
      } on Object {
        // The DLL may be loaded; its marker is cleaned on the next launch.
      }
    }
    notifyListeners();
    if (activeHere) {
      final next = remaining.where((s) => s.enabled);
      if (next.isNotEmpty) {
        await selectSource(next.first);
      } else {
        await enableLocalMode();
      }
    }
  }

  /// Deletes the decryptor DLLs a removed source installed, unless another
  /// installed source still declares the same module.
  Future<void> _removeUnusedDecryptors(
    List<DiscoveredSource> removed,
    List<DiscoveredSource> remaining,
  ) async {
    final registry = _decryptors;
    if (registry == null) return;
    String key(DecryptorSpec spec) => '${spec.id}\u0000${spec.version}';
    final inUse = <String>{};
    for (final source in remaining) {
      final manifest = source.manifest;
      // Without a manifest we cannot prove a module is unused; keep it.
      if (manifest == null) return;
      for (final spec in manifest.decryptors) {
        if (spec.id.isNotEmpty) inUse.add(key(spec));
      }
    }
    final unused = <DecryptorSpec>[];
    final seen = <String>{};
    for (final source in removed) {
      for (final spec in source.manifest?.decryptors ?? const <DecryptorSpec>[]) {
        if (!spec.downloadable) continue;
        final id = key(spec);
        if (inUse.contains(id) || !seen.add(id)) continue;
        unused.add(spec);
      }
    }
    if (unused.isEmpty) return;
    try {
      await registry.removeAll(unused);
    } on Object {
      // Deletion is best effort; a locked DLL is cleaned next launch.
    }
  }

  Future<void> selectSource(DiscoveredSource source) async {
    _preview = false;
    _clearImages();
    _gatewayState = _gatewayState.copyWith(
      activeSourceId: source.sourceId,
      localMode: false,
    );
    _activate(source);
    await _gatewayStore.save(_gatewayState);
    notifyListeners();
    await refreshUi();
  }

  /// Re-opens the active source so pages fetch from the current build. Used
  /// after a local source package was updated silently.
  Future<void> reloadActiveSource() async {
    final source = activeSource;
    if (source == null) return;
    _sourceRevision++;
    await selectSource(source);
  }

  Future<void> selectSourceById(String sourceId) async {
    for (final source in _gatewayState.sources) {
      if (source.sourceId == sourceId && source.enabled) {
        await selectSource(source);
        return;
      }
    }
  }

  Future<void> _refreshSources(String gatewayId) async {
    final client = _client;
    if (client == null) return;
    try {
      final manifests = await client.sources();
      final old = <String, DiscoveredSource>{
        for (final source in _gatewayState.sources)
          if (source.gatewayId == gatewayId) source.sourceId: source,
      };
      var changed = false;
      final next = <DiscoveredSource>[];
      for (final manifest in manifests) {
        final previous = old[manifest.id];
        if (previous == null ||
            previous.name != manifest.name ||
            previous.description != manifest.description ||
            !listEquals(previous.capabilities, manifest.capabilities)) {
          changed = true;
        }
        next.add(DiscoveredSource(
          gatewayId: gatewayId,
          sourceId: manifest.id,
          name: manifest.name,
          icon: manifest.icon,
          description: manifest.description,
          capabilities: manifest.capabilities,
          requiresAuth: manifest.auth?.required ?? false,
          enabled: previous?.enabled ?? true,
          isLocal: previous?.isLocal ?? _isLocalGateway(gatewayId),
          manifest: manifest,
        ));
      }
      if (!changed) return;
      _gatewayState = _gatewayState.copyWith(sources: [
        ..._gatewayState.sources.where((s) => s.gatewayId != gatewayId),
        ...next,
      ]);
      await _gatewayStore.save(_gatewayState);
      final active = activeSource;
      if (active != null && active.gatewayId == gatewayId) _activate(active);
      notifyListeners();
    } on Object {
      // Keep the cached discovery when the gateway is unreachable.
    }
  }

  /// The client is closed whenever the active source changes; a request that
  /// was in flight then fails with "Bad state: Client is closed". That is not
  /// a source failure, and it must not put a banner over the app — the page
  /// simply belongs to the gateway that was just replaced.
  static bool _isStaleClient(Object error) =>
      error is StateError && '$error'.toLowerCase().contains('client is closed');

  Future<void> refreshUi() async {
    final source = activeSource;
    if (source == null || _client == null) return;
    // Installing the core tears the gateway down and brings it back; asking
    // for data in between only produces failures the user cannot act on.
    if (_corePending) return;
    // Capabilities and names are part of the source manifest and can change
    // server-side (e.g. a source gains auth). Refresh them every launch so a
    // cached discovery from an older build does not hide features.
    await _refreshSources(source.gatewayId);
    final manifest = activeSource?.manifest;
    if (manifest != null) {
      unawaited(_ensureDecryptors(manifest.decryptors));
    }
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.uiJson(
        source.sourceId,
        clientPages: PageTypes.all,
      );
      // The manifest is fetched on every launch but only replaced when it
      // actually changed; a failed fetch keeps the cached one (set by
      // _activate), so the app still starts with the last good config.
      final encoded = jsonEncode(raw);
      final cached = _gatewayState.uiCache[source.cacheKey];
      if (cached != null && jsonEncode(cached) == encoded) {
        _error = null;
        return;
      }
      _uiManifest = UIManifest.fromJson(raw);
      _gatewayState = _gatewayState.copyWith(
        uiCache: {..._gatewayState.uiCache, source.cacheKey: raw},
      );
      await _gatewayStore.save(_gatewayState);
      _error = null;
    } catch (error) {
      // A cached menu stays usable when the gateway is unreachable.
      if (!_isStaleClient(error)) _error = _messageOf(error);
    } finally {
      notifyListeners();
    }
  }

  Future<void> enableLocalMode() async {
    _preview = false;
    _clearImages();
    _client?.close();
    _client = null;
    _sourceApi = null;
    _uiManifest = null;
    _gatewayState = _gatewayState.copyWith(
      localMode: true,
      activeSourceId: '',
    );
    await _gatewayStore.save(_gatewayState);
    notifyListeners();
  }

  Future<void> leaveLocalMode() async {
    _gatewayState = _gatewayState.copyWith(localMode: false);
    await _gatewayStore.save(_gatewayState);
    notifyListeners();
  }

  /// Debug-only demo data. Not persisted; not a user-visible source.
  Future<void> startPreview() async {
    try {
      final api = await PreviewSourceApi.load();
      _preview = true;
      _sourceApi = api;
      _uiManifest = api.ui;
      _error = null;
    } catch (error) {
      _error = _messageOf(error);
    }
    notifyListeners();
  }

  Future<void> exitPreview() async {
    _preview = false;
    _sourceApi = null;
    _uiManifest = null;
    final source = activeSource;
    if (source != null) {
      _activate(source);
    }
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    _settings = next;
    await _settingsStore.save(_settings);
    notifyListeners();
  }

  Future<void> setShowRecommendedSources(bool value) async {
    if (_settings.showRecommendedSources == value) return;
    await updateSettings(
      _settings.copyWith(showRecommendedSources: value),
    );
  }

  void setPendingLocalFile(String path) {
    _pendingLocalPath = path;
    notifyListeners();
  }

  String? consumePendingLocalFile() {
    final path = _pendingLocalPath;
    _pendingLocalPath = null;
    return path;
  }

  /// A source link handed over by the website (`freeplayer://source?url=…`).
  String? _pendingSourceUrl;

  String? get pendingSourceUrl => _pendingSourceUrl;

  void setPendingSourceUrl(String url) {
    _pendingSourceUrl = url;
    notifyListeners();
  }

  String? consumePendingSourceUrl() {
    final url = _pendingSourceUrl;
    _pendingSourceUrl = null;
    return url;
  }

  GatewayConfig? _gatewayFor(String gatewayId) {
    for (final gateway in _gatewayState.gateways) {
      if (gateway.id == gatewayId) return gateway;
    }
    return null;
  }

  bool _isLocalGateway(String gatewayId) {
    final gateway = _gatewayFor(gatewayId);
    return gateway != null && gateway.kind != 'remote';
  }

  void _activate(DiscoveredSource source) {
    final gateway = _gatewayFor(source.gatewayId);
    if (gateway == null) {
      _sourceApi = null;
      _uiManifest = null;
      return;
    }
    if (gateway.kind == 'local-js') {
      _client?.close();
      _client = null;
      _sourceApi = _localApis[gateway.id];
      _uiManifest = _localUi[gateway.id];
      _error = _sourceApi == null ? '本地源尚未加载' : null;
      unawaited(_warmFilters());
      return;
    }
    // A login belongs to the source, not to one client instance: carry it
    // over or switching away and back silently logs the user out.
    final saved = _client?.credentials ?? <String, Map<String, String>>{};
    _client?.close();
    final client = GatewayClient(
      baseUrl: gateway.baseUrl,
      clientId: _settings.clientId,
    )..restoreCredentials(saved);
    _client = client;
    final manifest = source.manifest ??
        SourceManifest(
          id: source.sourceId,
          name: source.name,
          protocol: '1',
          description: source.description,
          icon: source.icon,
          capabilities: source.capabilities,
        );
    _sourceApi = GatewaySourceApi(client, manifest);
    _uiManifest = _gatewayState.uiFor(source);
    // Warm the filter panels after startup so opening the category or rank
    // page does not wait on the selector request. Failures stay silent; the
    // page still has its own retry.
    unawaited(_warmFilters());
  }

  /// Installs hash-pinned decryption modules declared by the active source.
  /// A failed download never blocks browsing; the source can still serve
  /// plaintext or fail the play request with a decryptor error.
  Future<void> _ensureDecryptors(List<DecryptorSpec> specs) async {
    final registry = _decryptors;
    if (registry == null || specs.isEmpty) return;
    try {
      await registry.ensureAll(specs);
    } on Object {
      // Keep the source usable; playback reports the missing module.
    }
  }

  Future<void> _warmFilters() async {
    final api = _sourceApi;
    if (api == null) return;
    await Future.wait<void>([
      _ignoreFailure(api.categoryMeta()),
      _ignoreFailure(api.rankMeta()),
    ]);
  }

  Future<void> _ignoreFailure(Future<Object?> future) async {
    try {
      await future;
    } on Object {
      // The cache drops failed futures; the page can retry.
    }
  }

  DiscoveredSource _discoveredFrom(
    String gatewayId,
    SourceManifest manifest, {
    bool isLocal = false,
  }) {
    return DiscoveredSource(
      gatewayId: gatewayId,
      sourceId: manifest.id,
      name: manifest.name,
      icon: manifest.icon,
      description: manifest.description,
      capabilities: manifest.capabilities,
      requiresAuth: manifest.auth?.required ?? false,
      isLocal: isLocal,
      manifest: manifest,
    );
  }

  Uri _normalizeGateway(String rawUrl) {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const SpException(
        SpErrorCode.badRequest,
        '地址需要以 http:// 或 https:// 开头',
      );
    }
    return uri;
  }

  String _trimTrailingSlash(String value) {
    var result = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  String _messageOf(Object error) => describeGatewayError(error);

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  /// Covers belong to the old source; keeping them costs memory and can show
  /// the wrong artwork after a switch.
  void _clearImages() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  }

  @override
  void dispose() {
    for (final api in _localApis.values) {
      if (api is ClosableSourceApi) (api as ClosableSourceApi).close();
    }
    _localApis.clear();
    _client?.close();
    super.dispose();
  }
}
