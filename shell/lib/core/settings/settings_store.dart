import '../sp/models.dart';
import '../storage/local_store.dart';
import '../storage/paths.dart' as paths;
import 'settings.dart';

class SettingsStore {
  SettingsStore({
    required LocalStore store,
    required this.defaultDownloadDirectory,
  }) : _store = store;

  final LocalStore _store;
  final String defaultDownloadDirectory;

  Future<AppSettings> load() async {
    final data = await _store.read();
    final storedId = str(data['client_id']);
    final clientId = storedId.isEmpty ? AppSettings.newClientId() : storedId;
    final settings = AppSettings.fromJson(
      data,
      clientId: clientId,
      fallbackDownloadDirectory: defaultDownloadDirectory,
    );
    if (storedId.isEmpty) {
      await save(settings);
    }
    return settings;
  }

  Future<void> save(AppSettings settings) => _store.write(settings.toJson());

  static SettingsStore createDefault() {
    return SettingsStore(
      store: LocalStore(paths.appDataFile('settings.json')),
      defaultDownloadDirectory: paths.defaultDownloadDirectory(),
    );
  }
}
