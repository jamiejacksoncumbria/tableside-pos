import 'receipt_paper_width.dart';

/// A printer installed in Windows. Windows treats locally USB-connected and
/// network-connected hardware alike once its driver and queue have been added.
class WindowsPrintQueueDevice {
  const WindowsPrintQueueDevice({
    required this.name,
    required this.driverName,
    required this.portName,
    required this.isDefault,
    this.paperWidth = ReceiptPaperWidth.mm80,
  });

  final String name;
  final String driverName;
  final String portName;
  final bool isDefault;
  final ReceiptPaperWidth paperWidth;

  WindowsPrintQueueDevice copyWith({ReceiptPaperWidth? paperWidth}) =>
      WindowsPrintQueueDevice(
        name: name,
        driverName: driverName,
        portName: portName,
        isDefault: isDefault,
        paperWidth: paperWidth ?? this.paperWidth,
      );
}

class WindowsPrintQueueException implements Exception {
  const WindowsPrintQueueException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum WindowsPrintTextAlignment { left, center, right }

/// One formatted line on a Windows-driver receipt. [rightText] keeps a price
/// flush right while the item description wraps within the remaining width.
class WindowsPrintLine {
  const WindowsPrintLine(
    this.text, {
    this.rightText,
    this.alignment = WindowsPrintTextAlignment.left,
    this.bold = false,
    this.fontSizeDelta = 0,
  });

  final String text;
  final String? rightText;
  final WindowsPrintTextAlignment alignment;
  final bool bold;
  final int fontSizeDelta;

  Map<String, Object?> toMessage() => {
    'text': text,
    if (rightText != null) 'rightText': rightText,
    'alignment': alignment.name,
    'bold': bold,
    'fontSizeDelta': fontSizeDelta,
  };
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
    required List<WindowsPrintLine> lines,
  });

  Future<void> printTestTicket({
    required WindowsPrintQueueDevice printer,
    required String restaurantName,
  });
}
