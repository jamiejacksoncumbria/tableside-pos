import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/text_case.dart';

void main() {
  group('toCatalogueTitleCase', () {
    test('normalises words and whitespace', () {
      expect(
        toCatalogueTitleCase('  large   glass WHITE wine  '),
        'Large Glass White Wine',
      );
    });

    test('handles hyphenated and slash-separated labels', () {
      expect(toCatalogueTitleCase('sweet-and-sour'), 'Sweet-And-Sour');
      expect(toCatalogueTitleCase('gin/tonic'), 'Gin/Tonic');
    });

    test('retains catalogue acronyms and measurement casing', () {
      expect(toCatalogueTitleCase('ipa beer 50CL bbq'), 'IPA Beer 50cl BBQ');
      expect(toCatalogueTitleCase('vat 20'), 'VAT 20');
    });
  });
}
