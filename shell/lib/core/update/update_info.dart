/// One release offered by `/api/update/check` (see
/// `update_server/docs/CLIENT_UPDATE.md`).
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.channelLabel,
    required this.title,
    required this.date,
    required this.notes,
    required this.downloadUrl,
    required this.mirrorUrl,
    required this.manualUrl,
    required this.sha256,
    required this.size,
    required this.filename,
    required this.mode,
    required this.declineKey,
    required this.force,
  });

  final String version;
  final String channelLabel;
  final String title;
  final String date;
  final List<String> notes;
  final String downloadUrl;
  final String mirrorUrl;
  final String manualUrl;
  final String sha256;
  final int size;
  final String filename;
  final String mode;
  final String declineKey;
  final bool force;

  bool get hasArchive => downloadUrl.isNotEmpty && sha256.isNotEmpty;

  /// Returns null unless the server says the update should be shown now.
  static UpdateInfo? parse(Map<String, dynamic> json) {
    if (json['update_available'] != true || json['notify'] != true) {
      return null;
    }
    final latest = json['latest'];
    final download = json['download'];
    if (latest is! Map || download is! Map) return null;
    final notes = <String>[];
    final rawNotes = latest['notes'];
    if (rawNotes is List) {
      for (final note in rawNotes) {
        final text = note is Map ? '${note['text'] ?? ''}'.trim() : '$note'.trim();
        if (text.isNotEmpty) notes.add(text);
      }
    }
    return UpdateInfo(
      version: '${latest['version'] ?? ''}',
      channelLabel: '${latest['channel_label'] ?? ''}',
      title: '${latest['title'] ?? ''}',
      date: '${latest['date'] ?? ''}',
      notes: notes,
      downloadUrl: '${download['url'] ?? ''}',
      mirrorUrl: '${download['mirror_url'] ?? ''}',
      manualUrl: '${json['manual_url'] ?? download['manual_url'] ?? ''}',
      sha256: '${download['sha256'] ?? ''}',
      size: download['size'] is num ? (download['size'] as num).toInt() : 0,
      filename: '${download['filename'] ?? ''}',
      mode: '${download['mode'] ?? 'manual'}',
      declineKey: '${json['decline_key'] ?? ''}',
      force: json['force'] == true,
    );
  }
}
