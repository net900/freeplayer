import '../storage/local_store.dart';

/// Recent search terms, newest first. One JSON file, keyed by source: a term
/// typed against one source must not show up under another.
class SearchHistory {
  SearchHistory(this._store, {this.max = 30, this.scope = ''});

  final LocalStore _store;
  final int max;

  /// Source identity (its manifest id); empty keeps the pre-scope behaviour.
  final String scope;

  static const String _key = 'queries';

  List<String>? _cache;

  Future<List<String>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final data = await _store.read();
    final raw = data[_key];
    final list = <String>[];
    final source = raw is Map ? raw[scope] : (scope.isEmpty ? raw : null);
    if (source is List) {
      for (final value in source) {
        final text = value.toString().trim();
        if (text.isNotEmpty && !list.contains(text)) list.add(text);
      }
    }
    return _cache = list;
  }

  Future<List<String>> add(String query) async {
    final text = query.trim();
    if (text.isEmpty) return load();
    final list = [...await load()]..remove(text);
    list.insert(0, text);
    if (list.length > max) list.removeRange(max, list.length);
    return _save(list);
  }

  Future<List<String>> remove(String query) async {
    final list = [...await load()]..remove(query.trim());
    return _save(list);
  }

  Future<List<String>> clear() => _save(const []);

  Future<List<String>> _save(List<String> list) async {
    _cache = list;
    final data = await _store.read();
    final raw = data[_key];
    final map = <String, dynamic>{};
    if (raw is Map) {
      map.addAll(Map<String, dynamic>.from(raw));
    } else if (raw is List) {
      // A file written before per-source history stays readable.
      map[''] = raw;
    }
    map[scope] = list;
    await _store.write({_key: map});
    return list;
  }
}
