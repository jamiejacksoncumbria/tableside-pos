import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/printing/receipt_line_aggregation.dart';

void main() {
  test('combines matching paid receipt lines while retaining their total', () {
    final lines = aggregateReceiptPayloadLines([
      {
        'productId': 'efes',
        'productName': 'Efes',
        'quantity': 1,
        'unitPriceMinor': 22000,
        'lineTotalMinor': 22000,
        'taxRateId': 'alcohol',
        'taxRateBasisPoints': 2000,
      },
      {
        'productId': 'efes',
        'productName': 'Efes',
        'quantity': 2,
        'unitPriceMinor': 22000,
        'lineTotalMinor': 44000,
        'taxRateId': 'alcohol',
        'taxRateBasisPoints': 2000,
      },
    ]);

    expect(lines, hasLength(1));
    expect(lines.single.name, 'Efes');
    expect(lines.single.quantity, 3);
    expect(lines.single.lineTotalMinor, 66000);
  });

  test('does not combine receipt lines with different sale snapshots', () {
    final lines = aggregateReceiptPayloadLines([
      {
        'productId': 'efes',
        'productName': 'Efes',
        'quantity': 1,
        'unitPriceMinor': 22000,
        'lineTotalMinor': 22000,
        'taxRateId': 'alcohol',
        'taxRateBasisPoints': 2000,
      },
      {
        'productId': 'efes',
        'productName': 'Efes',
        'quantity': 1,
        'unitPriceMinor': 20000,
        'lineTotalMinor': 20000,
        'taxRateId': 'alcohol',
        'taxRateBasisPoints': 2000,
      },
    ]);

    expect(lines, hasLength(2));
  });

  test('keeps variants and modifiers distinct on a paid receipt', () {
    final lines = aggregateReceiptPayloadLines([
      {
        'productId': 'steak',
        'productName': 'Ribeye steak',
        'quantity': 1,
        'unitPriceMinor': 180000,
        'lineTotalMinor': 180000,
        'taxRateId': 'food',
        'taxRateBasisPoints': 1000,
        'variantName': 'Large',
        'modifierSelections': [
          {'groupName': 'Cooking', 'optionName': 'Medium rare'},
        ],
      },
      {
        'productId': 'steak',
        'productName': 'Ribeye steak',
        'quantity': 1,
        'unitPriceMinor': 180000,
        'lineTotalMinor': 180000,
        'taxRateId': 'food',
        'taxRateBasisPoints': 1000,
        'variantName': 'Large',
        'modifierSelections': [
          {'groupName': 'Cooking', 'optionName': 'Well done'},
        ],
      },
    ]);

    expect(lines, hasLength(2));
    expect(lines.first.name, contains('Cooking: Medium rare'));
    expect(lines.last.name, contains('Cooking: Well done'));
  });
}
