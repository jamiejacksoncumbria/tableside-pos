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
}
