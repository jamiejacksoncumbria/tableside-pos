import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  test('only completed/cancelled production states are terminal', () {
    expect(OrderFlowStatus.served.isTerminal, isTrue);
    expect(OrderFlowStatus.cancelled.isTerminal, isTrue);
    expect(OrderFlowStatus.voided.isTerminal, isTrue);
    expect(OrderFlowStatus.ready.isTerminal, isFalse);
    expect(OrderFlowStatus.preparing.isTerminal, isFalse);
  });

  test('venues use safe default order-flow warning thresholds', () {
    const venue = Venue(
      id: 'venue-1',
      tenantId: 'tenant-1',
      name: 'Spice Garden',
      timeZone: 'Asia/Famagusta',
    );

    expect(venue.orderFlowAmberMinutes, 15);
    expect(venue.orderFlowRedMinutes, 25);
    expect(venue.businessDayCutoffMinutes, 240);
  });

  test(
    'order line can be marked sent without losing immutable line details',
    () {
      const line = OrderLine(
        id: 'line-1',
        productId: 'water',
        productName: 'Water',
        quantity: 2,
        unitPriceMinor: 250,
        productionArea: ProductionArea.bar,
        trackStock: true,
      );

      final sent = line.copyWith(isSentToProduction: true);

      expect(sent.isSentToProduction, isTrue);
      expect(sent.productId, line.productId);
      expect(sent.totalMinor, 500);
    },
  );
}
