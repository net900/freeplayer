import '../storage/local_store.dart';
import 'models.dart';

class GatewayStore {
  GatewayStore(this._store);

  final LocalStore _store;

  Future<GatewayState> load() async {
    final data = await _store.read();
    return GatewayState.fromJson(data);
  }

  Future<void> save(GatewayState state) => _store.write(state.toJson());
}
