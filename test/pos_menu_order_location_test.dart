import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';
import 'package:tableside_pos/features/pos/pos_page.dart';

void main() {
  PosOrder order({
    String? tableId,
    String? tabName,
    OrderChannel channel = OrderChannel.dineIn,
    String? customerName,
  }) =>
      PosOrder(
        id: 'order-1',
        tenantId: 'tenant',
        venueId: 'venue',
        businessDate: DateTime(2026, 11, 1),
        openedAt: DateTime(2026, 11, 1, 12),
        status: OrderStatus.open,
        lines: const <OrderLine>[],
        tableId: tableId,
        tabName: tabName,
        channel: channel,
        customerName: customerName,
      );

  const tables = <DiningTable>[
    DiningTable(id: 'table-1', label: 'Table 1', seats: 4),
  ];

  test('menu toolbar identifies tables and named tabs', () {
    expect(posMenuOrderLocationLabel(order(), tables), 'New order');
    expect(
      posMenuOrderLocationLabel(order(tableId: 'table-1'), tables),
      'Table 1',
    );
    expect(
      posMenuOrderLocationLabel(order(tabName: 'Jamie'), tables),
      'Tab · Jamie',
    );
  });

  test('menu toolbar identifies collection and delivery customers', () {
    expect(
      posMenuOrderLocationLabel(
        order(
          channel: OrderChannel.collection,
          customerName: 'Bernadette',
        ),
        tables,
      ),
      'Collection · Bernadette',
    );
    expect(
      posMenuOrderLocationLabel(
        order(channel: OrderChannel.delivery, customerName: 'Jamie'),
        tables,
      ),
      'Delivery · Jamie',
    );
  });
}
