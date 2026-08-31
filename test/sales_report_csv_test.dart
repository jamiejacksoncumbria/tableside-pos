import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';
import 'package:tableside_pos/features/reports/reports_page.dart';

void main() {
  test('sales CSV preserves exact snapshots and escapes unsafe text', () {
    final bill = SalesReportBill(
      id: 'bill-1',
      receiptNumber: 'R-001',
      venueId: 'venue-1',
      businessDate: DateTime(2026, 8, 29),
      currencyCode: 'TRY',
      grossMinor: 12550,
      netMinor: 11409,
      taxMinor: 1141,
      closedByName: 'Jamie\nManager',
      payments: [
        SalesReportPayment(
          method: 'cash',
          currencyCode: 'EUR',
          tenderedAmountMinor: 300,
          baseAmountMinor: 12550,
        ),
      ],
      lines: [
        SalesReportLine(
          productId: 'fish',
          productName: 'Fish, "chips"',
          quantity: 1,
          grossMinor: 12550,
        ),
      ],
      taxBreakdown: [
        SalesReportTaxEntry(
          name: 'Food VAT',
          basisPoints: 1000,
          grossMinor: 12550,
          netMinor: 11409,
          taxMinor: 1141,
        ),
      ],
    );

    final csv = buildSalesReportCsv([bill], 'TRY');

    expect(csv, contains('BILL,29-08-2026,R-001,"Jamie\nManager"'));
    expect(csv, contains('PAYMENT,29-08-2026'));
    expect(csv, contains('EUR,3.00,125.50'));
    expect(csv, contains('"Fish, ""chips"""'));
    expect(csv, contains('Food VAT,10.00,125.50,114.09,11.41'));
    expect(csv, contains('\r\n'));
  });
}
