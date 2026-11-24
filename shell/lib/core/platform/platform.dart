import 'dart:io';

/// True on the desktop builds this shell grew up on: frameless window,
/// in-process core, native file dialogs.
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool get isMobilePlatform => !isDesktopPlatform;

bool get isAndroidPlatform => Platform.isAndroid;
