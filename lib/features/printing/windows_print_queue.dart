/// A printer installed in Windows. Windows treats locally USB-connected and
/// network-connected hardware alike once its driver and queue have been added.
class WindowsPrintQueueDevice {
  const WindowsPrintQueueDevice({
    required this.name,
    required this.driverName,
    required this.portName,
    required this.isDefault,
  });

  final String name;
  final String driverName;
  final String portName;
  final bool isDefault;
}

class WindowsPrintQueueException implements Exception {
  const WindowsPrintQueueException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Small platform boundary for printing through Windows' installed print
/// queues. This deliberately uses the vendor driver instead of talking to USB
/// directly, so USB and TCP/IP printers share the same reliable setup path.
abstract interface class WindowsPrintQueue {
  bool get isSupported;

  Future<List<WindowsPrintQueueDevice>> installedPrinters();

  Future<WindowsPrintQueueDevice?> selectedPrinter();

  Future<void> selectPrinter(WindowsPrintQueueDevice printer);

  Future<void> clearSelectedPrinter();

  Future<void> printText({
    required WindowsPrintQueueDevice printer,
    required String title,
    required List<String> lines,
  });

  Future<void> printTestTicket({
    required WindowsPrintQueueDevice printer,
    required String restaurantName,
  });
}
