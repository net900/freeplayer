import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/renderer/fallback_menu.dart';
import 'package:free_player/core/renderer/manifest_menu.dart';
import 'package:free_player/core/sp/models.dart';
import 'package:free_player/core/sp/page_types.dart';

void main() {
  test('unknown page types are dropped from the menu', () {
    final manifest = UIManifest(
      defaultPage: 'made.up',
      navigation: const [
        NavGroup(
          title: 'g',
          items: [
            NavItem(title: 'ok', page: PageTypes.search),
            NavItem(title: 'bad', page: 'made.up'),
          ],
        ),
      ],
    );
    final menu = buildMenu(
      manifest: manifest,
      capabilities: const [],
      localMode: false,
      supportedPages: PageTypes.all.toSet(),
    );
    expect(menu.length, 1);
    expect(menu.first.entries.map((entry) => entry.page), [PageTypes.search]);
    expect(defaultPageOf(manifest: manifest, menu: menu), PageTypes.search);
  });

  test('fallback manifest uses framework labels and capabilities', () {
    final manifest = fallbackManifest(
      capabilities: const ['feed', 'rank'],
      localMode: false,
    );
    expect(manifest.navigation, isNotEmpty);
    expect(manifest.defaultPage, PageTypes.homeFeed);
    final pages = manifest.navigation
        .expand((group) => group.items)
        .map((item) => item.page)
        .toList();
    expect(pages, contains(PageTypes.listRank));
    expect(pages, contains(PageTypes.libraryDownloads));
    expect(pages, isNot(contains(PageTypes.listNew)));
  });

  test('local mode menu exposes only local library pages', () {
    final manifest = fallbackManifest(capabilities: const ['feed'], localMode: true);
    final pages = manifest.navigation
        .expand((group) => group.items)
        .map((item) => item.page)
        .toSet();
    // Local playback has no account shelf and nothing to download.
    expect(pages, {PageTypes.libraryHistory});
  });
}
