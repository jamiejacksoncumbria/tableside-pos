import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  group('checkout payment policy', () {
    test('offers the venue currency and supported foreign cash tenders', () {
      expect(
        checkoutTenderCurrencies('try'),
        orderedEquals(<String>['TRY', 'EUR', 'GBP', 'USD']),
      );
      expect(
        checkoutTenderCurrencies('EUR'),
        orderedEquals(<String>['EUR', 'TRY', 'GBP', 'USD']),
      );
    });

    test('defaults paid receipt printing to selected', () {
      expect(defaultPrintPaidReceipt, isTrue);
    });

    test('normalises touch-keyboard exchange rates for audit storage', () {
      expect(normalizeExchangeRateInput(' 52,500001 '), '52.500001');
      expect(normalizeExchangeRateInput('1.25'), '1.25');
    });
  });
}
