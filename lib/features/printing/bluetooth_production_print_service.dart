import '../../core/tenant_scope.dart';
import '../pos/domain.dart';
import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';

/// Sends a production-safe ticket to the Bluetooth printer paired with this
/// device. It is intentionally used only after the server accepted the order,
/// so a failed local print never invents or changes a sale.
class BluetoothProductionPrintService {
  BluetoothProductionPrintService({BluetoothReceiptPrinter? printer})
    : _printer = printer ?? createBluetoothReceiptPrinter();

  final BluetoothReceiptPrinter _printer;

  Future<BluetoothProductionPrintResult> printNewLines({
    required VenueScope scope,
    required PosOrder order,
    required List<OrderLine> lines,
    required String restaurantName,
    required String tableLabel,
    required String createdByName,
  }) async {
    if (!_printer.isSupported || lines.isEmpty) {
      return const BluetoothProductionPrintResult();
    }
    final routingKey = '${scope.tenantId}_${scope.venueId}';
    final routing = await _printer.productionRouting(
      venueRoutingKey: routingKey,
    );
    if (!routing.enabled || routing.productionAreas.isEmpty) {
      return const BluetoothProductionPrintResult();
    }
    final device = await _printer.selectedDevice();
    if (device == null) {
      throw const BluetoothReceiptPrinterException(
        'This venue has Bluetooth production routing enabled, but no paired printer is selected on this device.',
      );
    }

    final grouped = <String, List<OrderLine>>{};
    for (final line in lines) {
      grouped.putIfAbsent(line.productionArea.name, () => []).add(line);
    }
    var printedTickets = 0;
    final skippedAreas = <String>[];
    for (final entry in grouped.entries) {
      if (!routing.routes(entry.key)) {
        skippedAreas.add(entry.key);
        continue;
      }
      await _printer.printProductionTicket(
        device: device,
        ticket: BluetoothProductionTicket(
          ticketId:
              '${order.id}_${entry.key}_${entry.value.map((line) => line.id).join('_')}',
          restaurantName: restaurantName,
          productionArea: entry.key,
          reference: order.id.split('-').last,
          tableLabel: order.tabName == null ? tableLabel : null,
          tabName: order.tabName,
          createdByName: createdByName,
          isAddition: order.status == OrderStatus.sent,
          lines: entry.value
              .map(
                (line) => BluetoothProductionTicketLine(
                  name: line.productName,
                  quantity: line.quantity,
                  details: line.productionDetails,
                ),
              )
              .toList(growable: false),
        ),
      );
      printedTickets++;
    }
    return BluetoothProductionPrintResult(
      ticketsPrinted: printedTickets,
      skippedProductionAreas: skippedAreas,
    );
  }
}

class BluetoothProductionPrintResult {
  const BluetoothProductionPrintResult({
    this.ticketsPrinted = 0,
    this.skippedProductionAreas = const <String>[],
  });

  final int ticketsPrinted;
  final List<String> skippedProductionAreas;
}
