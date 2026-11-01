import 'package:flutter/foundation.dart';

import '../sp/models.dart';
import '../sp/page_types.dart';
import 'fallback_menu.dart';

/// A menu node ready for rendering: unknown page types have already been
/// removed, so the sidebar cannot render something the shell cannot show.
class MenuEntry {
  const MenuEntry({
    required this.title,
    required this.icon,
    required this.page,
    this.params = const {},
    this.actions = const [],
  });

  final String title;
  final String icon;
  final String page;
  final Map<String, String> params;
  final List<NavAction> actions;
}

class MenuGroup {
  const MenuGroup({
    required this.title,
    required this.icon,
    required this.entries,
  });

  final String title;
  final String icon;
  final List<MenuEntry> entries;
}

/// Resolves the manifest the shell should draw and drops items whose page type
/// the shell does not implement (PRD §5.5, §6.6).
List<MenuGroup> buildMenu({
  required UIManifest? manifest,
  required List<String> capabilities,
  required bool localMode,
  required Set<String> supportedPages,
}) {
  final source = manifest ??
      fallbackManifest(capabilities: capabilities, localMode: localMode);

  final groups = <MenuGroup>[];
  for (final group in source.navigation) {
    final entries = <MenuEntry>[];
    for (final item in group.items) {
      if (!PageTypes.isKnown(item.page) || !supportedPages.contains(item.page)) {
        debugPrint('menu item "${item.title}" has unsupported page "${item.page}"');
        continue;
      }
      entries.add(MenuEntry(
        title: item.title,
        icon: item.icon,
        page: item.page,
        params: item.params,
        actions: item.actions,
      ));
    }
    if (entries.isEmpty) continue;
    groups.add(MenuGroup(
      title: group.title,
      icon: group.icon,
      entries: entries,
    ));
  }

  if (groups.isEmpty) {
    final fallback = fallbackManifest(
      capabilities: capabilities,
      localMode: localMode,
    );
    for (final group in fallback.navigation) {
      groups.add(MenuGroup(
        title: group.title,
        icon: group.icon,
        entries: group.items
            .where((item) => supportedPages.contains(item.page))
            .map((item) => MenuEntry(
                  title: item.title,
                  icon: item.icon,
                  page: item.page,
                  params: item.params,
                ))
            .toList(growable: false),
      ));
    }
  }
  return groups.where((group) => group.entries.isNotEmpty).toList(growable: false);
}

String defaultPageOf({
  required UIManifest? manifest,
  required List<MenuGroup> menu,
}) {
  final desired = manifest?.defaultPage ?? '';
  for (final group in menu) {
    for (final entry in group.entries) {
      if (entry.page == desired) return entry.page;
    }
  }
  return menu.isEmpty ? PageTypes.libraryHistory : menu.first.entries.first.page;
}
