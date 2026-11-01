import 'models.dart';

/// Quality policy from PRD §10.1: streams arrive sorted by height descending,
/// and "highest available" is the default.
abstract final class Quality {
  static const String auto = 'auto';
  static const String highest = 'highest';

  static const List<String> options = [
    auto,
    '1080p',
    '720p',
    '540p',
    '480p',
    '360p',
  ];

  /// Picks the stream the shell should play. The gateway already sorts, but a
  /// client-side check keeps direct-connect sources honest.
  static Stream? pick(List<Stream> streams, {String quality = auto, int maxHeight = 0}) {
    if (streams.isEmpty) return null;
    final sorted = [...streams]..sort((a, b) => b.height.compareTo(a.height));
    if (quality == auto || quality == highest) {
      for (final stream in sorted) {
        if (maxHeight <= 0 || stream.height <= maxHeight) return stream;
      }
      return sorted.first;
    }
    final wanted = _parseHeight(quality);
    if (wanted > 0) {
      for (final stream in sorted) {
        if (stream.height == wanted) {
          return maxHeight <= 0 || stream.height <= maxHeight ? stream : null;
        }
      }
    }
    for (final stream in sorted) {
      if (maxHeight <= 0 || stream.height <= maxHeight) return stream;
    }
    return sorted.first;
  }

  static int _parseHeight(String quality) {
    final match = RegExp(r'(\d{3,4})').firstMatch(quality);
    return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
  }
}
