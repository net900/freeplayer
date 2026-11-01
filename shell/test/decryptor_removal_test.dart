import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/decryptor/decryptor_registry.dart';
import 'package:free_player/core/sp/models.dart';
import 'package:free_player/core/storage/paths.dart';

void main() {
  const spec = DecryptorSpec(
    id: 'cenc-ctr',
    version: '1.0.0',
    url: 'https://example.com/cenc_decrypt.dll',
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    size: 3,
    file: 'cenc_decrypt.dll',
  );

  test('removeAll deletes the installed module and its empty id folder',
      () async {
    final root = await Directory.systemTemp.createTemp('fp-decryptor-');
    addTearDown(() => root.delete(recursive: true));
    final idDir = Directory(joinPath(root.path, 'cenc-ctr'));
    final versionDir = Directory(joinPath(idDir.path, '1.0.0'))
      ..createSync(recursive: true);
    File(joinPath(versionDir.path, 'cenc_decrypt.dll'))
        .writeAsBytesSync([1, 2, 3]);

    await DecryptorRegistry(directory: root).removeAll([spec]);

    expect(versionDir.existsSync(), isFalse);
    expect(idDir.existsSync(), isFalse);
  });

  test('a locked module is finished on the next launch', () async {
    final root = await Directory.systemTemp.createTemp('fp-decryptor-');
    addTearDown(() => root.delete(recursive: true));
    final versionDir = Directory(joinPath(joinPath(root.path, 'cenc-ctr'), '1.0.0'))
      ..createSync(recursive: true);
    File(joinPath(versionDir.path, 'cenc_decrypt.dll'))
        .writeAsBytesSync([1, 2, 3]);
    final marker = File('${versionDir.path}.remove')..writeAsStringSync('');

    await DecryptorRegistry(directory: root).cleanupPendingRemoval();

    expect(versionDir.existsSync(), isFalse);
    expect(marker.existsSync(), isFalse);
  });
}
