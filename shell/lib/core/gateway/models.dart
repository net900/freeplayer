import '../sp/models.dart';

class GatewayConfig {
  const GatewayConfig({
    required this.id,
    required this.baseUrl,
    this.name = '',
    this.apiKey = '',
    this.lastOkAt = '',
    this.kind = 'remote',
    this.localId = '',
  });

  final String id;
  final String baseUrl;
  final String name;
  final String apiKey;
  final String lastOkAt;

  /// 'remote' = HTTP gateway, 'core' = bundled local core,
  /// 'local-js' = source script executed inside the client.
  final String kind;

  /// Stable package id for a local-js source.
  final String localId;

  GatewayConfig copyWith({
    String? name,
    String? lastOkAt,
    String? apiKey,
    String? kind,
    String? localId,
  }) {
    return GatewayConfig(
      id: id,
      baseUrl: baseUrl,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      lastOkAt: lastOkAt ?? this.lastOkAt,
      kind: kind ?? this.kind,
      localId: localId ?? this.localId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'base_url': baseUrl,
        'name': name,
        'api_key': apiKey,
        'last_ok_at': lastOkAt,
        'kind': kind,
        'local_id': localId,
      };

  factory GatewayConfig.fromJson(Map<String, dynamic> json) {
    return GatewayConfig(
      id: str(json['id']),
      baseUrl: str(json['base_url']),
      name: str(json['name']),
      apiKey: str(json['api_key']),
      lastOkAt: str(json['last_ok_at']),
      kind: str(json['kind']).isEmpty ? 'remote' : str(json['kind']),
      localId: str(json['local_id']),
    );
  }
}

class DiscoveredSource {
  const DiscoveredSource({
    required this.gatewayId,
    required this.sourceId,
    this.name = '',
    this.icon = '',
    this.description = '',
    this.capabilities = const [],
    this.requiresAuth = false,
    this.enabled = true,
    this.isLocal = false,
    this.manifest,
  });

  final String gatewayId;
  final String sourceId;
  final String name;
  final String icon;
  final String description;
  final List<String> capabilities;
  final bool requiresAuth;
  final bool enabled;

  /// True for the bundled core and for downloaded local JS sources.
  final bool isLocal;

  final SourceManifest? manifest;

  String get cacheKey => '$gatewayId:$sourceId';

  DiscoveredSource copyWith({
    bool? enabled,
    bool? isLocal,
    SourceManifest? manifest,
  }) {
    return DiscoveredSource(
      gatewayId: gatewayId,
      sourceId: sourceId,
      name: name,
      icon: icon,
      description: description,
      capabilities: capabilities,
      requiresAuth: requiresAuth,
      enabled: enabled ?? this.enabled,
      isLocal: isLocal ?? this.isLocal,
      manifest: manifest ?? this.manifest,
    );
  }

  Map<String, dynamic> toJson() => {
        'gateway_id': gatewayId,
        'source_id': sourceId,
        'name': name,
        'icon': icon,
        'description': description,
        'capabilities': capabilities,
        'requires_auth': requiresAuth,
        'enabled': enabled,
        'is_local': isLocal,
        'manifest': manifest == null ? null : _manifestToJson(manifest!),
      };

  factory DiscoveredSource.fromJson(Map<String, dynamic> json) {
    final rawManifest = json['manifest'];
    return DiscoveredSource(
      gatewayId: str(json['gateway_id']),
      sourceId: str(json['source_id']),
      name: str(json['name']),
      icon: str(json['icon']),
      description: str(json['description']),
      capabilities: stringList(json['capabilities']),
      requiresAuth: boolOr(json['requires_auth']),
      enabled: boolOr(json['enabled'], true),
      isLocal: boolOr(json['is_local']),
      manifest: rawManifest is Map
          ? SourceManifest.fromJson(mapOr(rawManifest))
          : null,
    );
  }
}

Map<String, dynamic> _manifestToJson(SourceManifest manifest) => {
      'id': manifest.id,
      'name': manifest.name,
      'version': manifest.version,
      'protocol': manifest.protocol,
      'description': manifest.description,
      'icon': manifest.icon,
      'capabilities': manifest.capabilities,
      'extra': manifest.extra,
      if (manifest.auth != null)
        'auth': {
          'required': manifest.auth!.required,
          'methods': manifest.auth!.methods,
        },
    };

class GatewayState {
  const GatewayState({
    this.gateways = const [],
    this.sources = const [],
    this.uiCache = const {},
    this.activeSourceId = '',
    this.localMode = false,
  });

  final List<GatewayConfig> gateways;
  final List<DiscoveredSource> sources;
  final Map<String, Map<String, dynamic>> uiCache;
  final String activeSourceId;
  final bool localMode;

  GatewayConfig? get gatewayForActiveSource {
    final source = activeSource;
    if (source == null) return null;
    for (final gateway in gateways) {
      if (gateway.id == source.gatewayId) return gateway;
    }
    return null;
  }

  DiscoveredSource? get activeSource {
    for (final source in sources) {
      if (source.sourceId == activeSourceId && source.enabled) return source;
    }
    return null;
  }

  UIManifest? uiFor(DiscoveredSource source) {
    final cached = uiCache[source.cacheKey];
    return cached == null ? null : UIManifest.fromJson(cached);
  }

  GatewayState copyWith({
    List<GatewayConfig>? gateways,
    List<DiscoveredSource>? sources,
    Map<String, Map<String, dynamic>>? uiCache,
    String? activeSourceId,
    bool? localMode,
  }) {
    return GatewayState(
      gateways: gateways ?? this.gateways,
      sources: sources ?? this.sources,
      uiCache: uiCache ?? this.uiCache,
      activeSourceId: activeSourceId ?? this.activeSourceId,
      localMode: localMode ?? this.localMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'gateways': gateways.map((g) => g.toJson()).toList(),
        'sources': sources.map((s) => s.toJson()).toList(),
        'ui_cache': uiCache,
        'active_source_id': activeSourceId,
        'local_mode': localMode,
      };

  factory GatewayState.fromJson(Map<String, dynamic> json) {
    final uiCache = <String, Map<String, dynamic>>{};
    mapOr(json['ui_cache']).forEach((key, value) {
      if (value is Map) uiCache[key] = mapOr(value);
    });
    return GatewayState(
      gateways: listOr(json['gateways'])
          .map((e) => GatewayConfig.fromJson(mapOr(e)))
          .toList(growable: false),
      sources: listOr(json['sources'])
          .map((e) => DiscoveredSource.fromJson(mapOr(e)))
          .toList(growable: false),
      uiCache: uiCache,
      activeSourceId: str(json['active_source_id']),
      localMode: boolOr(json['local_mode']),
    );
  }
}
