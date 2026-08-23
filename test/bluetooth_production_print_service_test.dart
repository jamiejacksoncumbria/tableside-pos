import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/features/pos/domain.dart';
import 'package:tableside_pos/features/printing/bluetooth_production_print_service.dart';
import 'package:tableside_pos/features/printing/bluetooth_receipt_printer.dart';

void main() {
  final scope = VenueScope(tenantId: 'tenant-1', venueId: 'venue-1');
  final order = PosOrder(
    id: 'order-123',
    tenantId: scope.tenantId,
    venueId: scope.venueId,
    tableId: 'table-1',
    businessDate: DateTime(2026, 8, 23),
    openedAt: DateTime(2026, 8, 23, 12),
    status: OrderStatus.open,
    lines: const [],
  );

  test('prints only production areas enabled for this venue', () async {
    final printer = _FakePrinter(
      routing: const BluetoothProductionRouting(
        enabled: true,
        productionAreas: {'bar'},
      ),
    );
    final result = await BluetoothProductionPrintService(
      printer: printer,
    ).printNewLines(
      scope: scope,
      order: order,
      lines: const [
        OrderLine(
          id: 'bar-line',
          productId: 'cola',
          productName: 'Cola',
          quantity: 2,
          unitPriceMinor: 500,
          productionArea: ProductionArea.bar,
          trackStock: false,
        ),
        OrderLine(
          id: 'kitchen-line',
          productId: 'curry',
          productName: 'Chicken curry',
          quantity: 1,
          unitPriceMinor: 1200,
          productionArea: ProductionArea.kitchen,
          trackStock: false,
        ),
      ],
      restaurantName: 'Spice Garden',
      tableLabel: '2',
      createdByName: 'Jamie',
    );

    expect(result.ticketsPrinted, 1);
    expect(result.skippedProductionAreas, ['kitchen']);
    expect(printer.productionTickets, hasLength(1));
    final ticket = printer.productionTickets.single;
    expect(ticket.productionArea, 'bar');
    expect(ticket.tableLabel, '2');
    expect(ticket.lines.single.name, 'Cola');
    expect(ticket.lines.single.quantity, 2);
  });

  test('does nothing when live production routing is disabled', () async {
    final printer = _FakePrinter();
    final result = await BluetoothProductionPrintService(
      printer: printer,
    ).printNewLines(
      scope: scope,
      order: order,
      lines: const [
        OrderLine(
          id: 'kitchen-line',
          productId: 'curry',
          productName: 'Chicken curry',
          quantity: 1,
          unitPriceMinor: 1200,
          productionArea: ProductionArea.kitchen,
          trackStock: false,
        ),
      ],
      restaurantName: 'Spice Garden',
      tableLabel: '2',
      createdByName: 'Jamie',
    );

    expect(result.ticketsPrinted, 0);
    expect(printer.productionTickets, isEmpty);
  });
}

class _FakePrinter implements BluetoothReceiptPrinter {
  _FakePrinter({
    this.routing = const BluetoothProductionRouting(),
  });

  final BluetoothProductionRouting routing;
  final productionTickets = <BluetoothProductionTicket>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> clearSelectedDevice() async {}

  @override
  Future<List<BluetoothReceiptPrinterDevice>> pairedDevices() async => const [];

  @override
  Future<void> printProductionTicket({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothProductionTicket ticket,
  }) async {
    productionTickets.add(ticket);
  }

  @override
  Future<void> printTestTicket({
    required BluetoothReceiptPrinterDevice device,
    required String restaurantName,
  }) async {}

  @override
  Future<BluetoothProductionRouting> productionRouting({
    required String venueRoutingKey,
  }) async => routing;

  @override
  Future<void> saveProductionRouting({
    required String venueRoutingKey,
    required BluetoothProductionRouting routing,
  }) async {}

  @override
  Future<BluetoothReceiptPrinterDevice?> selectedDevice() async =>
      const BluetoothReceiptPrinterDevice(name: 'MPT-II', address: '01:02');

  @override
  Future<void> selectDevice(BluetoothReceiptPrinterDevice device) async {}
}
