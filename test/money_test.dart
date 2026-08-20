import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/money.dart';

void main() {
  group('formatMoney', () {
    test('formats a two-decimal currency using its ISO code', () {
      expect(
        formatMoney(275, currencyCode: 'GBP'),
        'GBP 2.75',
      );
    });

    test(
      'uses the correct number of decimal places for a zero-decimal currency',
      () {
        expect(
        formatMoney(275, currencyCode: 'JPY'),
          'JPY 275',
        );
      },
    );

    test(
      'uses the correct number of decimal places for a three-decimal currency',
      () {
        expect(
        formatMoney(12345, currencyCode: 'KWD'),
          'KWD 12.345',
        );
      },
    );
  });
}
