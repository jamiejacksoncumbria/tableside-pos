import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';
import 'native_print_worker.dart';
import 'receipt_line_aggregation.dart';

/// Translates server-created printer payloads into ESC/POS bytes. Production
/// jobs deliberately remain price-free; paid receipts can only be created for
/// a device configured for the separate `receipt` route.
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
    if (payload['type'] == 'receipt') {
      await _printReceipt(
        selectedDevice: selectedDevice,
        payload: payload,
        idempotencyKey: idempotencyKey,
      );
      return;
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
        isReprint: payload['isReprint'] as bool? ?? false,
        lines: lines,
      ),
    );
  }

  Future<void> _printReceipt({
    required BluetoothReceiptPrinterDevice selectedDevice,
    required Map<String, Object?> payload,
    required String idempotencyKey,
  }) async {
    final lines = aggregateReceiptPayloadLines(payload['lines'])
        .map(
          (line) => BluetoothBillReceiptLine(
            name: line.name,
            quantity: line.quantity,
            lineTotalMinor: line.lineTotalMinor,
          ),
        )
        .toList(growable: false);
    if (lines.isEmpty) {
      throw const BluetoothReceiptPrinterException(
        'The queued paid receipt does not contain any bill lines.',
      );
    }
    final rawPayments = payload['payments'];
    final payments = rawPayments is List
        ? rawPayments
              .whereType<Map>()
              .map(
                (payment) => BluetoothReceiptPayment(
                  method: payment['method'] as String? ?? 'Payment',
                  amountMinor:
                      (payment['tenderedAmountMinor'] as num?)?.toInt() ??
                      (payment['baseAmountMinor'] as num?)?.toInt() ??
                      0,
                  currencyCode:
                      payment['tenderedCurrencyCode'] as String? ??
                      payload['currencyCode'] as String? ??
                      'GBP',
                ),
              )
              .toList(growable: false)
        : const <BluetoothReceiptPayment>[];
    final rawTaxBreakdown = payload['taxBreakdown'];
    final taxBreakdown = rawTaxBreakdown is List
        ? rawTaxBreakdown
              .whereType<Map>()
              .map(
                (tax) => BluetoothReceiptTaxBreakdown(
                  name: tax['taxRateName'] as String? ?? 'Tax',
                  basisPoints:
                      (tax['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
                  taxMinor: (tax['taxMinor'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(growable: false)
        : const <BluetoothReceiptTaxBreakdown>[];
    final business = payload['business'] is Map
        ? Map<Object?, Object?>.from(payload['business'] as Map)
        : const <Object?, Object?>{};
    final phoneNumbers = business['phoneNumbers'] is List
        ? (business['phoneNumbers'] as List).whereType<String>().toList(
            growable: false,
          )
        : const <String>[];
    await _printer.printBillReceipt(
      device: selectedDevice,
      receipt: BluetoothBillReceipt(
        receiptNumber: payload['receiptNumber'] as String? ?? idempotencyKey,
        restaurantName:
            business['name'] as String? ??
            payload['restaurantName'] as String? ??
            'TABLESIDE POS',
        currencyCode: payload['currencyCode'] as String? ?? 'GBP',
        tableLabel: payload['tableLabel'] as String?,
        tabName: payload['tabName'] as String?,
        businessDate: payload['businessDate'] as String?,
        totalMinor: (payload['totalMinor'] as num?)?.toInt() ?? 0,
        taxTotalMinor: (payload['taxTotalMinor'] as num?)?.toInt() ?? 0,
        netTotalMinor: (payload['netTotalMinor'] as num?)?.toInt(),
        lines: lines,
        payments: payments,
        taxBreakdown: taxBreakdown,
        businessAddress: business['address'] as String? ?? '',
        businessPhoneNumbers: phoneNumbers,
        receiptFooter: business['receiptFooter'] as String? ?? '',
        isReprint: payload['isReprint'] as bool? ?? false,
      ),
    );
  }
}
