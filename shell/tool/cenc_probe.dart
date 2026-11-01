// Checks that the CENC library can be located and loaded (symbols match).
// Run from shell/:  dart run tool/cenc_probe.dart
import 'dart:io';

import 'package:free_player/core/decryptor/cenc_native.dart';

void main() {
  final path = CencNative.findLibrary();
  stdout.writeln('library: ${path ?? '-'}');
  final native = CencNative.ensureLoaded();
  stdout.writeln('loaded: ${native != null}');
  if (native == null) exitCode = 1;
}
