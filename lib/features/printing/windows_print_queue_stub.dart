import 'windows_print_queue.dart';

WindowsPrintQueue createWindowsPrintQueue() =>
    const _UnsupportedWindowsPrintQueue();

class _UnsupportedWindowsPrintQueue implements WindowsPrintQueue {
  const _UnsupportedWindowsPrintQueue();

  @override
  bool get isSupported => false;

  @override
  Future<void> clearSelectedPrinter() async {}

  @override
  Future<List<WindowsPrintQueueDevice>> installedPrinters() {
    throw const WindowsPrintQueueException(
      'Windows USB and network printer support is available only in the Windows desktop app.',
    );
  }

  @override
  Future<void> printTestTicket({
    required WindowsPrintQueueDevice printer,
    required String restaurantName,
  }) {
    throw const WindowsPrintQueueException(
      'Windows printer support is not available in this app target.',
    );
  }

  @override
  Future<void> printText({
    required WindowsPrintQueueDevice printer,
    required String title,
    required List<WindowsPrintLine> lines,
  }) {
    throw const WindowsPrintQueueException(
      'Windows printer support is not available in this app target.',
    );
  }

  @override
  Future<void> selectPrinter(WindowsPrintQueueDevice printer) async {}

  @override
  Future<WindowsPrintQueueDevice?> selectedPrinter() async => null;
}
