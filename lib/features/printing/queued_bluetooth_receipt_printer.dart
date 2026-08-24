import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';
import 'native_print_worker.dart';

/// Translates a server-created, price-free print-job payload into ESC/POS
/// bytes. It deliberately accepts no sale totals, payment details, or contact
/// information, so a kitchen/bar device cannot expose customer money data.
class QueuedBluetoothReceiptPrinter implements NativeReceiptPrinter {
  QueuedBluetoothReceiptPrinter({BluetoothReceiptPrinter? printer})
    : _printer = printer ?? createBluetoothReceiptPrinter();

  final BluetoothReceiptPrinter _printer;

  @override
  Future<void> printTicket({
    required Map<String, Object?> payload,
    required String idempotencyKey,
  }) async {
    final selectedDevice = await _printer.selectedDevice();
    if (selectedDevice == null) {
      throw const BluetoothReceiptPrinterException(
        'This registered printer device has no selected Bluetooth printer.',
      );
    }
    final rawLines = payload['lines'];
    final lines = rawLines is List
        ? rawLines
              .whereType<Map>()
              .map(
                (line) => BluetoothProductionTicketLine(
                  name: line['name'] as String? ?? 'Item',
                  quantity: line['quantity'] as int? ?? 1,
                ),
              )
              .toList(growable: false)
        : const <BluetoothProductionTicketLine>[];
    if (lines.isEmpty) {
      throw const BluetoothReceiptPrinterException(
        'The queued print job does not contain any ticket lines.',
      );
    }
    await _printer.printProductionTicket(
      device: selectedDevice,
      ticket: BluetoothProductionTicket(
        ticketId: payload['ticketId'] as String? ?? idempotencyKey,
        restaurantName: payload['restaurantName'] as String? ?? 'TABLESIDE POS',
        productionArea: payload['productionArea'] as String? ?? 'kitchen',
        reference: payload['reference'] as String? ?? idempotencyKey,
        tableLabel: payload['tableLabel'] as String?,
        tabName: payload['tabName'] as String?,
        createdByName: payload['createdByName'] as String?,
        isAddition: payload['isAddition'] as bool? ?? false,
        lines: lines,
      ),
    );
  }
}
