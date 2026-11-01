import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/pages/page_builders.dart';
import 'package:free_player/core/sp/page_types.dart';

void main() {
  test('registry implements exactly the protocol page types', () {
    final registry = buildPageRegistry();
    expect(registry.registeredTypes.toSet(), PageTypes.all.toSet());
  });

  test('unknown page types are rejected by the registry', () {
    final registry = buildPageRegistry();
    expect(registry.supports('made.up'), isFalse);
    expect(
      () => registry.register('made.up', (_, __) => throw UnimplementedError()),
      throwsArgumentError,
    );
  });

  test('client capability header lists every page type', () {
    for (final type in PageTypes.all) {
      expect(PageTypes.clientPagesHeader().split(','), contains(type));
    }
  });
}
