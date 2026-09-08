import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/printing/queued_windows_receipt_printer.dart';
import 'package:tableside_pos/features/printing/receipt_paper_width.dart';
import 'package:tableside_pos/features/printing/windows_print_queue.dart';

void main() {
  test('Windows vouchers use a fixed-size graphical QR matrix', () async {
    final queue = _RecordingWindowsPrintQueue(ReceiptPaperWidth.mm58);
    final printer = QueuedWindowsReceiptPrinter(printer: queue);

    await printer.printTicket(
      payload: const {
        'type': 'giftVoucher',
        'restaurantName': 'Test Venue',
        'amountMinor': 2500,
        'currencyCode': 'GBP',
        'code': 'TABLESIDE-TEST-VOUCHER-123456',
      },
      idempotencyKey: 'voucher-test',
    );

    final qrLine = queue.printedLines.singleWhere(
      (line) => line.qrRows != null,
    );
    expect(qrLine.qrSizeMillimetres, 28);
    expect(qrLine.qrRows!.length, greaterThanOrEqualTo(21));
    expect(
      qrLine.qrRows!.every((row) => row.length == qrLine.qrRows!.length),
      isTrue,
    );
    expect(
      qrLine.qrRows!.every((row) => RegExp(r'^[01]+$').hasMatch(row)),
      isTrue,
    );
  });
}

class _RecordingWindowsPrintQueue implements WindowsPrintQueue {
  _RecordingWindowsPrintQueue(this.paperWidth);

  final ReceiptPaperWidth paperWidth;
  List<WindowsPrintLine> printedLines = const [];

  @override
  bool get isSupported => true;

  @override
  Future<void> clearSelectedPrinter() async {}

  @override
  Future<List<WindowsPrintQueueDevice>> installedPrinters() async => const [];

  @override
  Future<void> printTestTicket({
    required WindowsPrintQueueDevice printer,
    required String restaurantName,
  }) async {}

  @override
  Future<void> printText({
    required WindowsPrintQueueDevice printer,
    required String title,
    required List<WindowsPrintLine> lines,
  }) async {
    printedLines = lines;
  }

  @override
  Future<void> selectPrinter(WindowsPrintQueueDevice printer) async {}

  @override
  Future<WindowsPrintQueueDevice?> selectedPrinter() async =>
      WindowsPrintQueueDevice(
        name: 'Test printer',
        driverName: 'Test driver',
        portName: 'USB001',
        isDefault: true,
        paperWidth: paperWidth,
      );
}
