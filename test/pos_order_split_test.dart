import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  test('a separate bill retains its parent relationship and item snapshot', () {
    const sourceLine = OrderLine(
      id: 'source-line',
      productId: 'main',
      productName: 'Main course',
      quantity: 2,
      unitPriceMinor: 1295,
      productionArea: ProductionArea.kitchen,
      trackStock: true,
      isSentToProduction: true,
    );
    final parent = PosOrder(
      id: 'parent-order',
      tenantId: 'tenant-1',
      venueId: 'venue-1',
      tableId: 'table-1',
      businessDate: DateTime(2026, 8, 27),
      openedAt: DateTime(2026, 8, 27),
      status: OrderStatus.sent,
      lines: const [sourceLine],
      openSplitOrderIds: const ['child-order'],
    );
    final child = parent.copyWith(
      id: 'child-order',
      lines: const [sourceLine],
      splitFromOrderId: parent.id,
      splitSequence: 1,
    );

    expect(parent.openSplitOrderIds, contains('child-order'));
    expect(child.isSplitOrder, isTrue);
    expect(child.splitFromOrderId, parent.id);
    expect(child.totalMinor, 2590);
    expect(child.lines.single.isSentToProduction, isTrue);
  });

  test('payments reduce the balance without closing the order model', () {
    final order = PosOrder(
      id: 'open-order',
      tenantId: 'tenant-1',
      venueId: 'venue-1',
      businessDate: DateTime(2026, 9, 12),
      openedAt: DateTime(2026, 9, 12),
      status: OrderStatus.sent,
      lines: const [
        OrderLine(
          id: 'line-1',
          productId: 'meal',
          productName: 'Meal',
          quantity: 1,
          unitPriceMinor: 10000,
          productionArea: ProductionArea.kitchen,
          trackStock: false,
          isSentToProduction: true,
        ),
      ],
      payments: [
        OrderPayment(
          id: 'payment-1',
          method: 'cash',
          tenderedAmountMinor: 3000,
          tenderedCurrencyCode: 'TRY',
          baseAmountMinor: 3000,
          exchangeRateToBase: '1',
          recordedAt: DateTime(2026, 9, 12, 18, 30),
        ),
      ],
    );

    expect(order.paidMinor, 3000);
    expect(order.balanceDueMinor, 7000);
    expect(order.status, OrderStatus.sent);
  });
}
