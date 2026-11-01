import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/app/app_controller.dart';
import 'package:free_player/core/gateway/gateway_store.dart';
import 'package:free_player/core/gateway/models.dart';
import 'package:free_player/core/settings/settings_store.dart';
import 'package:free_player/core/storage/local_store.dart';

void main() {
  test('legacy 555 and Hongguo sources are removed once', () async {
    final temp = Directory.systemTemp.createTempSync('fp_cleanup_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final gatewaysFile = File('${temp.path}/gateways.json');
    final settingsFile = File('${temp.path}/settings.json');

    const legacy = GatewayState(
      gateways: [
        GatewayConfig(
          id: 'http://127.0.0.1:8790',
          baseUrl: 'http://127.0.0.1:8790',
          name: '127.0.0.1',
        ),
        GatewayConfig(
          id: 'core:local',
          baseUrl: 'http://127.0.0.1:55712',
          name: '本地核心',
          kind: 'core',
        ),
      ],
      sources: [
        DiscoveredSource(
          gatewayId: 'http://127.0.0.1:8790',
          sourceId: 'dy555',
          name: '555电影',
        ),
        DiscoveredSource(
          gatewayId: 'core:local',
          sourceId: 'hongguo',
          name: '红果短剧',
          isLocal: true,
        ),
      ],
      activeSourceId: 'dy555',
    );
    gatewaysFile.writeAsStringSync(jsonEncode(legacy.toJson()));

    final controller = AppController(
      settingsStore: SettingsStore(
        store: LocalStore(settingsFile),
        defaultDownloadDirectory: temp.path,
      ),
      gatewayStore: GatewayStore(LocalStore(gatewaysFile)),
    );
    await controller.init();

    expect(controller.enabledSources, isEmpty);
    expect(controller.activeSource, isNull);
    expect(
      controller.gateways
          .any((gateway) => gateway.id == 'http://127.0.0.1:8790'),
      isFalse,
    );
    expect(
      controller.gateways.any((gateway) => gateway.id == 'core:local'),
      isTrue,
    );
    expect(controller.settings.legacySourcesRemoved, isTrue);

    final savedSettings = jsonDecode(settingsFile.readAsStringSync()) as Map;
    expect(savedSettings['legacy_sources_removed'], isTrue);
  });

  test('recommended source visibility is saved', () async {
    final temp = Directory.systemTemp.createTempSync('fp_settings_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final store = SettingsStore(
      store: LocalStore(File('${temp.path}/settings.json')),
      defaultDownloadDirectory: temp.path,
    );

    final initial = await store.load();
    expect(initial.showRecommendedSources, isTrue);
    await store.save(initial.copyWith(showRecommendedSources: false));

    final loaded = await store.load();
    expect(loaded.showRecommendedSources, isFalse);
  });
}
