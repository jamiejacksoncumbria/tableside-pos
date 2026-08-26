import 'receipt_paper_width.dart';

/// A printer paired in the operating system's Bluetooth settings.
class BluetoothReceiptPrinterDevice {
  const BluetoothReceiptPrinterDevice({
    required this.name,
    required this.address,
    this.paperWidth = ReceiptPaperWidth.mm58,
  });

  final String name;
  final String address;
  final ReceiptPaperWidth paperWidth;

  BluetoothReceiptPrinterDevice copyWith({ReceiptPaperWidth? paperWidth}) =>
      BluetoothReceiptPrinterDevice(
        name: name,
        address: address,
        paperWidth: paperWidth ?? this.paperWidth,
      );
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

/// A money-bearing ticket that is accepted only by a printer device routed as
/// `receipt`. Kitchen/bar jobs retain their deliberately price-free payload.
class BluetoothBillReceipt {
  const BluetoothBillReceipt({
    required this.receiptNumber,
    required this.restaurantName,
    required this.currencyCode,
    required this.lines,
    required this.totalMinor,
    required this.taxTotalMinor,
    this.netTotalMinor,
    this.tableLabel,
    this.tabName,
    this.businessDate,
    this.payments = const <BluetoothReceiptPayment>[],
    this.taxBreakdown = const <BluetoothReceiptTaxBreakdown>[],
  });

  final String receiptNumber;
  final String restaurantName;
  final String currencyCode;
  final List<BluetoothBillReceiptLine> lines;
  final int totalMinor;
  final int taxTotalMinor;
  final int? netTotalMinor;
  final String? tableLabel;
  final String? tabName;
  final String? businessDate;
  final List<BluetoothReceiptPayment> payments;
  final List<BluetoothReceiptTaxBreakdown> taxBreakdown;
}

class BluetoothBillReceiptLine {
  const BluetoothBillReceiptLine({
    required this.name,
    required this.quantity,
    required this.lineTotalMinor,
  });

  final String name;
  final int quantity;
  final int lineTotalMinor;
}

class BluetoothReceiptPayment {
  const BluetoothReceiptPayment({
    required this.method,
    required this.amountMinor,
    required this.currencyCode,
  });

  final String method;
  final int amountMinor;
  final String currencyCode;
}

class BluetoothReceiptTaxBreakdown {
  const BluetoothReceiptTaxBreakdown({
    required this.name,
    required this.basisPoints,
    required this.taxMinor,
  });

  final String name;
  final int basisPoints;
  final int taxMinor;
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

  Future<void> printBillReceipt({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothBillReceipt receipt,
  });
}
