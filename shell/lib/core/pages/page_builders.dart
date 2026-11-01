import '../renderer/page_registry.dart';
import '../sp/page_types.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'home_feed_page.dart';
import 'library_page.dart';
import 'new_page.dart';
import 'player_page.dart';
import 'rank_page.dart';
import 'search_page.dart';

/// The complete mapping from protocol page types to shell widgets.
PageRegistry buildPageRegistry() {
  final registry = PageRegistry();

  registry.register(
    PageTypes.homeFeed,
    (context, ctx) => HomeFeedPage(ctx: ctx),
  );
  registry.register(
    PageTypes.search,
    (context, ctx) => SearchPage(
      initialQuery: ctx.params['q'] ?? '',
      ctx: ctx,
    ),
  );
  registry.register(
    PageTypes.listRank,
    (context, ctx) => RankPage(ctx: ctx),
  );
  registry.register(
    PageTypes.listNew,
    (context, ctx) => NewPage(ctx: ctx),
  );
  registry.register(
    PageTypes.listCategory,
    (context, ctx) => CategoryPage(ctx: ctx),
  );
  registry.register(
    PageTypes.detail,
    (context, ctx) => DetailPage(ctx: ctx),
  );
  registry.register(
    PageTypes.libraryHistory,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryHistory),
  );
  registry.register(
    PageTypes.libraryFollow,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryFollow),
  );
  registry.register(
    PageTypes.libraryReservations,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryReservations),
  );
  registry.register(
    PageTypes.libraryLikes,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryLikes),
  );
  registry.register(
    PageTypes.libraryFavorites,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryFavorites),
  );
  registry.register(
    PageTypes.libraryDownloads,
    (context, ctx) => const LibraryPage(type: PageTypes.libraryDownloads),
  );
  registry.register(
    PageTypes.player,
    (context, ctx) => PlayerPage(ctx: ctx),
  );

  return registry;
}
