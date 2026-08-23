/// A printer paired in the operating system's Bluetooth settings.
class BluetoothReceiptPrinterDevice {
  const BluetoothReceiptPrinterDevice({
    required this.name,
    required this.address,
  });

  final String name;
  final String address;
}

/// Local routing for the printer paired with this physical device. The route
/// is deliberately keyed by venue so staff carrying a device between venues
/// cannot accidentally print a venue's orders at another venue.
class BluetoothProductionRouting {
  const BluetoothProductionRouting({
    this.enabled = false,
    this.productionAreas = const <String>{},
  });

  final bool enabled;
  final Set<String> productionAreas;

  bool routes(String productionArea) =>
      enabled && productionAreas.contains(productionArea);
}

/// A price-free payload for a kitchen, bar, or dessert ticket.
class BluetoothProductionTicket {
  const BluetoothProductionTicket({
    required this.ticketId,
    required this.restaurantName,
    required this.productionArea,
    required this.reference,
    required this.lines,
    this.tableLabel,
    this.tabName,
    this.createdByName,
    this.isAddition = false,
  });

  final String ticketId;
  final String restaurantName;
  final String productionArea;
  final String reference;
  final List<BluetoothProductionTicketLine> lines;
  final String? tableLabel;
  final String? tabName;
  final String? createdByName;
  final bool isAddition;
}

class BluetoothProductionTicketLine {
  const BluetoothProductionTicketLine({
    required this.name,
    required this.quantity,
  });

  final String name;
  final int quantity;
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

  Future<BluetoothProductionRouting> productionRouting({
    required String venueRoutingKey,
  });

  Future<void> saveProductionRouting({
    required String venueRoutingKey,
    required BluetoothProductionRouting routing,
  });

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

  Future<void> printProductionTicket({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothProductionTicket ticket,
  });
}
