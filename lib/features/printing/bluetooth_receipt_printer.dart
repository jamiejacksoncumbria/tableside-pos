/// A printer paired in the operating system's Bluetooth settings.
class BluetoothReceiptPrinterDevice {
  const BluetoothReceiptPrinterDevice({
    required this.name,
    required this.address,
  });

  final String name;
  final String address;
}

class BluetoothReceiptPrinterException implements Exception {
  const BluetoothReceiptPrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A deliberately small printer boundary. It lets the first Bluetooth pilot
/// prove hardware printing before the Firebase print queue is connected to a
/// venue's configured routes.
abstract interface class BluetoothReceiptPrinter {
  bool get isSupported;

  Future<List<BluetoothReceiptPrinterDevice>> pairedDevices();

  Future<BluetoothReceiptPrinterDevice?> selectedDevice();

  Future<void> selectDevice(BluetoothReceiptPrinterDevice device);

  Future<void> clearSelectedDevice();

  /// Connects to [device] and writes a real 58 mm ESC/POS test ticket.
  ///
  /// Completion means the bytes were accepted by the Bluetooth transport. A
  /// small Bluetooth printer cannot reliably report that the paper physically
  /// emerged, so staff must confirm the printed ticket before live routing is
  /// enabled.
  Future<void> printTestTicket({
    required BluetoothReceiptPrinterDevice device,
    required String restaurantName,
  });
}
