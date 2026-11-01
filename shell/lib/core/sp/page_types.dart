/// The closed registry of page types the shell can render (PRD §5.7.9, §6.6).
/// Sources may not invent new types; unknown types are hidden and logged.
abstract final class PageTypes {
  static const String homeFeed = 'home.feed';
  static const String search = 'search';
  static const String listRank = 'list.rank';
  static const String listNew = 'list.new';
  static const String listCategory = 'list.category';
  static const String detail = 'detail';
  static const String libraryHistory = 'library.history';
  static const String libraryFollow = 'library.follow';
  static const String libraryReservations = 'library.reservations';
  static const String libraryLikes = 'library.likes';
  static const String libraryFavorites = 'library.favorites';
  static const String libraryDownloads = 'library.downloads';
  static const String player = 'player';

  static const List<String> all = [
    homeFeed,
    search,
    listRank,
    listNew,
    listCategory,
    detail,
    libraryHistory,
    libraryFollow,
    libraryReservations,
    libraryLikes,
    libraryFavorites,
    libraryDownloads,
    player,
  ];

  static const Set<String> library = {
    libraryHistory,
    libraryFollow,
    libraryReservations,
    libraryLikes,
    libraryFavorites,
    libraryDownloads,
  };

  static bool isKnown(String type) => all.contains(type);

  static bool isLibrary(String type) => library.contains(type);

  /// Page types the shell advertises through `X-Client-Pages`.
  static String clientPagesHeader() => all.join(',');
}
