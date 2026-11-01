import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:free_player/core/gateway/source_api.dart';
import 'package:free_player/core/pages/rank_page.dart';
import 'package:free_player/core/renderer/page_registry.dart';
import 'package:free_player/core/sp/models.dart';

/// Minimal SourceApi: only ranking calls are exercised by the page.
class _FakeRankApi implements SourceApi {
  _FakeRankApi(this.respond);

  final Future<ItemPage> Function(String cursor) respond;
  final List<String> cursors = <String>[];

  @override
  Future<ItemPage> rank({
    String type = '',
    String sub = '',
    String panel = '',
    String time = '',
    String filter = '',
    String cursor = '',
    int limit = 20,
  }) {
    cursors.add(cursor);
    return respond(cursor);
  }

  @override
  Future<RankMeta> rankMeta({String type = '', String sub = ''}) async =>
      const RankMeta();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Item> _page(String prefix) =>
    List<Item>.generate(10, (i) => Item(id: '$prefix$i', title: '$prefix-$i'));

ItemPage _pageResult(String cursor) {
  switch (cursor) {
    case '':
      return ItemPage(items: _page('a'), next: '10');
    case '10':
      return ItemPage(items: _page('b'), next: '20');
    case '20':
      return ItemPage(items: _page('c'), next: '');
  }
  return const ItemPage();
}

Widget _wrap(SourceApi api) => MaterialApp(
      home: Scaffold(
        body: RankPage(ctx: const PageContext(), api: api),
      ),
    );

void main() {
  testWidgets('rank page keeps filling past the first page', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = _FakeRankApi((cursor) async => _pageResult(cursor));
    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    // The first page alone does not fill the viewport, so the page must have
    // fetched the next one on its own.
    expect(api.cursors, contains(''));
    expect(api.cursors, contains('10'));

    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(api.cursors, contains('20'));
  });

  testWidgets('a scroll during an in-flight page does not drop it',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final firstPage = Completer<ItemPage>();
    final api = _FakeRankApi((cursor) {
      if (cursor == '') return Future<ItemPage>.value(_pageResult(''));
      if (cursor == '10') return firstPage.future;
      return Future<ItemPage>.value(_pageResult(cursor));
    });

    await tester.pumpWidget(_wrap(api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    // Page two is now in flight; scrolling must not invalidate it.
    expect(api.cursors, contains('10'));
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pump();

    firstPage.complete(ItemPage(items: _page('b'), next: '20'));
    await tester.pumpAndSettle();

    // With the response applied, _next advances and a later scroll loads p3.
    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(api.cursors, contains('20'));
  });
}
