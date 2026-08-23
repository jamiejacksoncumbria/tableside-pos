import 'bluetooth_receipt_printer.dart';

BluetoothReceiptPrinter createBluetoothReceiptPrinter() =>
    const _UnsupportedBluetoothReceiptPrinter();

class _UnsupportedBluetoothReceiptPrinter implements BluetoothReceiptPrinter {
  const _UnsupportedBluetoothReceiptPrinter();

  @override
  bool get isSupported => false;

  @override
  Future<void> clearSelectedDevice() async {}

  @override
  Future<BluetoothProductionRouting> productionRouting({
    required String venueRoutingKey,
  }) async => const BluetoothProductionRouting();

  @override
  Future<List<BluetoothReceiptPrinterDevice>> pairedDevices() {
    throw const BluetoothReceiptPrinterException(
      'Bluetooth receipt printing is available only in the native Android or Windows app.',
    );
  }

  @override
  Future<void> printTestTicket({
    required BluetoothReceiptPrinterDevice device,
    required String restaurantName,
  }) {
    throw const BluetoothReceiptPrinterException(
      'Bluetooth receipt printing is not available in this app target.',
    );
  }

  @override
  Future<void> printProductionTicket({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothProductionTicket ticket,
  }) {
    throw const BluetoothReceiptPrinterException(
      'Bluetooth receipt printing is not available in this app target.',
    );
  }

  @override
  Future<void> saveProductionRouting({
    required String venueRoutingKey,
    required BluetoothProductionRouting routing,
  }) async {}

  @override
  Future<void> selectDevice(BluetoothReceiptPrinterDevice device) async {}

  @override
  Future<BluetoothReceiptPrinterDevice?> selectedDevice() async => null;
}
