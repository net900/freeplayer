import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/l10n/loading_phrases.dart';

void main() {
  test('loading phrases are unique and non-empty', () {
    expect(kLoadingPhrases, isNotEmpty);
    expect(kLoadingPhrases.toSet().length, kLoadingPhrases.length);
    for (final phrase in kLoadingPhrases) {
      expect(phrase.trim(), isNotEmpty);
    }
  });

  test('every phrase fits in one short line of UI copy', () {
    for (final phrase in kLoadingPhrases) {
      expect(phrase.length, lessThanOrEqualTo(24));
    }
  });
}
