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

  test('sales CSV records refunds as negative immutable corrections', () {
    final refund = SalesReportRefund(
      id: 'refund-1',
      billId: 'bill-1',
      refundNumber: 'R-R-001-0001',
      originalReceiptNumber: 'R-001',
      venueId: 'venue-1',
      businessDate: DateTime(2026, 8, 29),
      currencyCode: 'TRY',
      grossMinor: 5000,
      netMinor: 4545,
      taxMinor: 455,
      reason: 'Customer complaint',
      refundedByName: 'Manager',
      payments: const [
        SalesReportPayment(
          method: 'cardTerminal',
          currencyCode: 'TRY',
          tenderedAmountMinor: 5000,
          baseAmountMinor: 5000,
          terminalLabel: 'Card Plus 1',
        ),
      ],
      lines: const [
        SalesReportLine(
          id: 'line-1',
          productId: 'meal',
          productName: 'Meal',
          quantity: 1,
          grossMinor: 5000,
        ),
      ],
      taxBreakdown: const [
        SalesReportTaxEntry(
          name: 'Food VAT',
          basisPoints: 1000,
          grossMinor: 5000,
          netMinor: 4545,
          taxMinor: 455,
        ),
      ],
    );

    final csv = buildSalesReportCsv(const [], 'TRY', [refund]);

    expect(csv, contains('REFUND,29-08-2026,R-R-001-0001'));
    expect(csv, contains('-50.00,-45.45,-4.55'));
    expect(csv, contains('REFUND_PAYMENT'));
    expect(csv, contains('REFUND_ITEM'));
    expect(csv, contains('R-001,Customer complaint'));
  });
}
