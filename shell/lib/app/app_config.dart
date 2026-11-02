/// Build-time address of the website's recommended source list.
///
/// Override it for a local `update_server`:
/// `flutter run -d windows --dart-define=FP_RECOMMENDED_SOURCES_URL=http://127.0.0.1:8090/api/sources?featured=1`
///
/// The default is the live site, so a plain build shows the same list as the
/// website.
const String recommendedSourcesEndpoint = String.fromEnvironment(
  'FP_RECOMMENDED_SOURCES_URL',
  defaultValue: 'https://freeplayer.8a5.cn/api/sources?featured=1',
);

/// Version reported to the update service; stamped at build time.
const String appVersion = String.fromEnvironment(
  'FP_APP_VERSION',
  defaultValue: '0.1.3',
);

/// The source served by the embedded core. Adding it installs the core.
const String coreSourceId = 'hongguo';

/// `stable` for normal builds, `beta` for test builds.
const String updateChannel = String.fromEnvironment(
  'FP_UPDATE_CHANNEL',
  defaultValue: 'stable',
);

/// Update endpoint served by the website (`update_server`'s
/// `/api/update/check`). Override for a local server:
/// `--dart-define=FP_UPDATE_URL=http://127.0.0.1:8090/api/update/check`
const String updateCheckEndpoint = String.fromEnvironment(
  'FP_UPDATE_URL',
  defaultValue: 'https://freeplayer.8a5.cn/api/update/check',
);

/// Where the client learns which source core (DLL) to download. The source
/// gateway announces the version and address; the file itself is fetched and
/// verified by the client. Override when packaging:
/// `--dart-define=FP_CORE_URL=https://example.com/api/core/check`
const String coreCheckEndpoint = String.fromEnvironment(
  'FP_CORE_URL',
  defaultValue: 'https://free-hg.8a5.cn/api/core/check',
);

String get updateChannelLabel => updateChannel == 'beta' ? '测试版' : '正式版';

/// Project links shown in 设置 → 关于.
const String projectWebsite = String.fromEnvironment(
  'FP_WEBSITE',
  defaultValue: 'https://freeplayer.8a5.cn',
);

const String projectRepository = 'https://github.com/net900/freeplayer';
