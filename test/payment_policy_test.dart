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
  });
}
