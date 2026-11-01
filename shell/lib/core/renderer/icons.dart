import 'package:flutter/material.dart';

/// Icons are referenced by name from the source manifest. Unknown names fall
/// back to a neutral glyph instead of breaking the menu.
IconData iconFor(String name) {
  switch (name) {
    case 'home':
      return Icons.home_outlined;
    case 'search':
      return Icons.search;
    case 'leaderboard':
    case 'rank':
      return Icons.leaderboard_outlined;
    case 'fiber_new':
    case 'new':
      return Icons.fiber_new_outlined;
    case 'category':
      return Icons.category_outlined;
    case 'video_library':
    case 'library':
      return Icons.video_library_outlined;
    case 'movie':
    case 'film':
      return Icons.movie_outlined;
    case 'tv':
    case 'series':
      return Icons.tv_outlined;
    case 'mic':
    case 'variety':
      return Icons.mic_none;
    case 'animation':
    case 'anime':
      return Icons.animation;
    case 'bolt':
    case 'short':
      return Icons.bolt_outlined;
    case 'history':
      return Icons.history;
    case 'favorite':
      return Icons.favorite_border;
    case 'download':
      return Icons.download_outlined;
    case 'playlist':
    case 'playlist_play':
      return Icons.playlist_play_outlined;
    case 'settings':
      return Icons.settings_outlined;
    case 'login':
      return Icons.login;
    case 'account':
      return Icons.account_circle_outlined;
    default:
      return Icons.circle_outlined;
  }
}
