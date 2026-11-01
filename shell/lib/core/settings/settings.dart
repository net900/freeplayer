import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;

import '../sp/models.dart';
import '../sp/quality.dart';

enum StartPage { lastLocation, fixedPage, home }

enum PlayerKernel { auto, system, builtin }

/// Client settings from PRD §18.2. Defaults live here, never inline in pages.
class AppSettings {
  const AppSettings({
    required this.clientId,
    this.themeMode = ThemeMode.system,
    this.defaultQuality = Quality.auto,
    this.downloadQuality = Quality.auto,
    this.maxConcurrentDownloads = 3,
    this.downloadSegments = 6,
    this.downloadDirectory = '',
    this.offlineQuotaGB = 20,
    this.autoPlayNext = true,
    this.rememberProgress = true,
    this.aggregateSearch = true,
    this.startPage = StartPage.lastLocation,
    this.allowWebview = false,
    this.playerKernel = PlayerKernel.auto,
    this.decryptorDirectory = './decryptors',
    this.danmakuFontSize = 16,
    this.danmakuOpacity = 1.0,
    this.danmakuSpeed = 1.0,
    this.volume = 1.0,
    this.preloadAhead = 4,
    this.updateDeclinedKey = '',
    this.showRecommendedSources = true,
    this.legacySourcesRemoved = false,
  });

  final String clientId;
  final ThemeMode themeMode;
  final String defaultQuality;
  final String downloadQuality;
  final int maxConcurrentDownloads;

  /// Parallel HLS segment connections used by one download.
  final int downloadSegments;
  final String downloadDirectory;
  final int offlineQuotaGB;
  final bool autoPlayNext;
  final bool rememberProgress;
  final bool aggregateSearch;
  final StartPage startPage;
  final bool allowWebview;
  final PlayerKernel playerKernel;
  final String decryptorDirectory;

  /// Danmaku overlay: text size, ink opacity and travel speed (1.0 = normal).
  final double danmakuFontSize;
  final double danmakuOpacity;
  final double danmakuSpeed;

  /// Player volume, so a new page and a preloaded engine start at the level
  /// the user set instead of 100%.
  final double volume;

  /// How many upcoming works/episodes are opened paused in spare engines.
  final int preloadAhead;

  /// The build the user dismissed ("稍后再说"); the same build is not
  /// prompted again. A repack changes the key and may prompt again.
  final String updateDeclinedKey;

  /// Whether the source page shows the website's recommended list.
  final bool showRecommendedSources;

  /// One-time cleanup flag for the old pre-added 555 / Hongguo entries.
  final bool legacySourcesRemoved;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? defaultQuality,
    String? downloadQuality,
    int? maxConcurrentDownloads,
    int? downloadSegments,
    String? downloadDirectory,
    int? offlineQuotaGB,
    bool? autoPlayNext,
    bool? rememberProgress,
    bool? aggregateSearch,
    StartPage? startPage,
    bool? allowWebview,
    PlayerKernel? playerKernel,
    String? decryptorDirectory,
    double? danmakuFontSize,
    double? danmakuOpacity,
    double? danmakuSpeed,
    double? volume,
    int? preloadAhead,
    String? updateDeclinedKey,
    bool? showRecommendedSources,
    bool? legacySourcesRemoved,
  }) {
    return AppSettings(
      clientId: clientId,
      themeMode: themeMode ?? this.themeMode,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      downloadSegments: downloadSegments ?? this.downloadSegments,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      offlineQuotaGB: offlineQuotaGB ?? this.offlineQuotaGB,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      rememberProgress: rememberProgress ?? this.rememberProgress,
      aggregateSearch: aggregateSearch ?? this.aggregateSearch,
      startPage: startPage ?? this.startPage,
      allowWebview: allowWebview ?? this.allowWebview,
      playerKernel: playerKernel ?? this.playerKernel,
      decryptorDirectory: decryptorDirectory ?? this.decryptorDirectory,
      danmakuFontSize: danmakuFontSize ?? this.danmakuFontSize,
      danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
      danmakuSpeed: danmakuSpeed ?? this.danmakuSpeed,
      volume: volume ?? this.volume,
      preloadAhead: preloadAhead ?? this.preloadAhead,
      updateDeclinedKey: updateDeclinedKey ?? this.updateDeclinedKey,
      showRecommendedSources:
          showRecommendedSources ?? this.showRecommendedSources,
      legacySourcesRemoved: legacySourcesRemoved ?? this.legacySourcesRemoved,
    );
  }

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'theme_mode': _themeModeName(themeMode),
        'default_quality': defaultQuality,
        'download_quality': downloadQuality,
        'max_concurrent_downloads': maxConcurrentDownloads,
        'download_segments': downloadSegments,
        'download_directory': downloadDirectory,
        'offline_quota_gb': offlineQuotaGB,
        'auto_play_next': autoPlayNext,
        'remember_progress': rememberProgress,
        'aggregate_search': aggregateSearch,
        'start_page': startPage.name,
        'allow_webview': allowWebview,
        'player_kernel': playerKernel.name,
        'decryptor_directory': decryptorDirectory,
        'danmaku_font_size': danmakuFontSize,
        'danmaku_opacity': danmakuOpacity,
        'danmaku_speed': danmakuSpeed,
        'volume': volume,
        'preload_ahead': preloadAhead,
        'update_declined_key': updateDeclinedKey,
        'show_recommended_sources': showRecommendedSources,
        'legacy_sources_removed': legacySourcesRemoved,
      };

  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    required String clientId,
    required String fallbackDownloadDirectory,
  }) {
    final defaults = AppSettings(
      clientId: clientId,
      downloadDirectory: fallbackDownloadDirectory,
    );
    final concurrency = intOr(
        json['max_concurrent_downloads'], defaults.maxConcurrentDownloads);
    final quota = intOr(json['offline_quota_gb'], defaults.offlineQuotaGB);
    final segments = intOr(json['download_segments'], defaults.downloadSegments);
    return AppSettings(
      clientId: clientId,
      themeMode: _themeMode(str(json['theme_mode'])),
      defaultQuality:
          _quality(str(json['default_quality']), defaults.defaultQuality),
      downloadQuality:
          _quality(str(json['download_quality']), defaults.downloadQuality),
      maxConcurrentDownloads: concurrency.clamp(1, 5),
      downloadSegments: segments.clamp(1, 12),
      downloadDirectory: str(json['download_directory']).isEmpty
          ? fallbackDownloadDirectory
          : str(json['download_directory']),
      offlineQuotaGB: quota.clamp(5, 200),
      autoPlayNext: boolOr(json['auto_play_next'], defaults.autoPlayNext),
      rememberProgress:
          boolOr(json['remember_progress'], defaults.rememberProgress),
      aggregateSearch:
          boolOr(json['aggregate_search'], defaults.aggregateSearch),
      startPage: _startPage(str(json['start_page'])),
      allowWebview: boolOr(json['allow_webview'], defaults.allowWebview),
      playerKernel: _playerKernel(str(json['player_kernel'])),
      decryptorDirectory: str(json['decryptor_directory']).isEmpty
          ? defaults.decryptorDirectory
          : str(json['decryptor_directory']),
      danmakuFontSize: (json['danmaku_font_size'] is num
              ? (json['danmaku_font_size'] as num).toDouble()
              : defaults.danmakuFontSize)
          .clamp(12.0, 28.0),
      danmakuOpacity: (json['danmaku_opacity'] is num
              ? (json['danmaku_opacity'] as num).toDouble()
              : defaults.danmakuOpacity)
          .clamp(0.25, 1.0),
      danmakuSpeed: (json['danmaku_speed'] is num
              ? (json['danmaku_speed'] as num).toDouble()
              : defaults.danmakuSpeed)
          .clamp(0.5, 2.5),
      volume: (json['volume'] is num
              ? (json['volume'] as num).toDouble()
              : defaults.volume)
          .clamp(0.0, 1.0),
      preloadAhead:
          intOr(json['preload_ahead'], defaults.preloadAhead).clamp(1, 4),
      updateDeclinedKey: str(json['update_declined_key']),
      showRecommendedSources: boolOr(
        json['show_recommended_sources'],
        defaults.showRecommendedSources,
      ),
      legacySourcesRemoved: boolOr(
        json['legacy_sources_removed'],
        defaults.legacySourcesRemoved,
      ),
    );
  }

  static String newClientId() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

String _themeModeName(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

ThemeMode _themeMode(String value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

String _quality(String value, String fallback) =>
    Quality.options.contains(value) ? value : fallback;

StartPage _startPage(String value) {
  for (final page in StartPage.values) {
    if (page.name == value) return page;
  }
  return StartPage.lastLocation;
}

PlayerKernel _playerKernel(String value) {
  for (final kernel in PlayerKernel.values) {
    if (kernel.name == value) return kernel;
  }
  return PlayerKernel.auto;
}
