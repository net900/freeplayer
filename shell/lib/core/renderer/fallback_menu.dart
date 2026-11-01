import '../../l10n/strings.dart';
import '../sp/models.dart';
import '../sp/page_types.dart';

/// Builds a menu when a source provides no ui_manifest. Labels are framework
/// i18n keys, not business content (PRD §6.6).
UIManifest fallbackManifest({
  required List<String> capabilities,
  bool localMode = false,
}) {
  if (localMode) {
    return UIManifest(
      defaultPage: PageTypes.libraryHistory,
      navigation: [
        NavGroup(
          title: AppStrings.navLibrary,
          icon: 'video_library',
          items: [
            // Local playback has no account shelf and nothing to download
            // from a source: history is the whole library here. Files in
            // play appear directly in the sidebar.
            NavItem(
              title: AppStrings.navHistory,
              icon: 'history',
              page: PageTypes.libraryHistory,
            ),
          ],
        ),
      ],
    );
  }

  final contentItems = <NavItem>[];
  if (capabilities.contains('feed')) {
    contentItems.add(NavItem(
      title: AppStrings.navContent,
      icon: 'home',
      page: PageTypes.homeFeed,
    ));
  }
  contentItems.add(NavItem(
    title: AppStrings.navSearch,
    icon: 'search',
    page: PageTypes.search,
  ));
  if (capabilities.contains('rank')) {
    contentItems.add(NavItem(
      title: AppStrings.navRank,
      icon: 'leaderboard',
      page: PageTypes.listRank,
    ));
  }
  if (capabilities.contains('new')) {
    contentItems.add(NavItem(
      title: AppStrings.navNew,
      icon: 'fiber_new',
      page: PageTypes.listNew,
    ));
  }
  if (capabilities.contains('category')) {
    contentItems.add(NavItem(
      title: AppStrings.navCategories,
      icon: 'category',
      page: PageTypes.listCategory,
    ));
  }

  return UIManifest(
    defaultPage: contentItems.first.page,
    navigation: [
      NavGroup(
        title: AppStrings.navContent,
        icon: 'home',
        items: contentItems,
      ),
      NavGroup(
        title: AppStrings.navLibrary,
        icon: 'video_library',
        items: [
          NavItem(
            title: AppStrings.navHistory,
            icon: 'history',
            page: PageTypes.libraryHistory,
          ),
          NavItem(
            title: AppStrings.navFavorites,
            icon: 'favorite',
            page: PageTypes.libraryFavorites,
          ),
          NavItem(
            title: AppStrings.navFollow,
            icon: 'update',
            page: PageTypes.libraryFollow,
          ),
          NavItem(
            title: AppStrings.navReservations,
            icon: 'event_available',
            page: PageTypes.libraryReservations,
          ),
          NavItem(
            title: AppStrings.navLikes,
            icon: 'thumb_up',
            page: PageTypes.libraryLikes,
          ),
          NavItem(
            title: AppStrings.navDownloads,
            icon: 'download',
            page: PageTypes.libraryDownloads,
          ),
        ],
      ),
    ],
  );
}
