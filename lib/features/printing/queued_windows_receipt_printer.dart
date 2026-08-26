import 'native_print_worker.dart';
import 'receipt_line_aggregation.dart';
import 'receipt_paper_width.dart';
import 'windows_print_queue.dart';
import 'windows_print_queue_factory.dart';

/// Prints server-validated jobs using the Windows driver selected on this PC.
/// Production tickets deliberately contain no money; only the dedicated
/// receipt route receives payment and tax lines.
class QueuedWindowsReceiptPrinter implements NativeReceiptPrinter {
  QueuedWindowsReceiptPrinter({WindowsPrintQueue? printer})
    : _printer = printer ?? createWindowsPrintQueue();

  final WindowsPrintQueue _printer;

  @override
  Future<void> printTicket({
    required Map<String, Object?> payload,
    required String idempotencyKey,
  }) async {
    final selectedPrinter = await _printer.selectedPrinter();
    if (selectedPrinter == null) {
      throw const WindowsPrintQueueException(
        'This registered Windows device has no selected print queue.',
      );
    }
    final isReceipt = payload['type'] == 'receipt';
    final lines = isReceipt
        ? _receiptLines(payload, idempotencyKey, selectedPrinter.paperWidth)
        : _productionLines(payload, idempotencyKey);
    await _printer.printText(
      printer: selectedPrinter,
      title: isReceipt
          ? 'TableSide paid receipt'
          : 'TableSide production ticket',
      lines: lines,
    );
  }

  List<WindowsPrintLine> _productionLines(
    Map<String, Object?> payload,
    String idempotencyKey,
  ) {
    final rawLines = payload['lines'];
    final items = rawLines is List
        ? rawLines
              .whereType<Map>()
              .map((line) {
                final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
                final name = line['name'] as String? ?? 'Item';
                return '$quantity x $name';
              })
              .toList(growable: false)
        : const <String>[];
    if (items.isEmpty) {
      throw const WindowsPrintQueueException(
        'The queued production ticket does not contain any items.',
      );
    }
    final area = switch (payload['productionArea']) {
      'bar' => 'BAR',
      'dessert' => 'DESSERT',
      _ => 'KITCHEN',
    };
    final tabName = payload['tabName'] as String?;
    final tableLabel = payload['tableLabel'] as String?;
    final location = tabName?.trim().isNotEmpty == true
        ? 'Tab: ${tabName!.trim()}'
        : tableLabel?.trim().isNotEmpty == true
        ? 'Table: ${tableLabel!.trim()}'
        : 'Order location unavailable';
    final reference = payload['reference'] as String? ?? idempotencyKey;
    return [
      WindowsPrintLine(
        payload['restaurantName'] as String? ?? 'TABLESIDE POS',
        alignment: WindowsPrintTextAlignment.center,
        bold: true,
        fontSizeDelta: 2,
      ),
      WindowsPrintLine(
        payload['isAddition'] == true ? '$area ADDITION' : area,
        alignment: WindowsPrintTextAlignment.center,
        bold: true,
      ),
      const WindowsPrintLine(''),
      WindowsPrintLine(location),
      WindowsPrintLine('Order #$reference'),
      if ((payload['createdByName'] as String?)?.trim().isNotEmpty == true)
        WindowsPrintLine('By: ${(payload['createdByName'] as String).trim()}'),
      const WindowsPrintLine(''),
      ...items.map((item) => WindowsPrintLine(item)),
      const WindowsPrintLine(''),
      WindowsPrintLine(
        payload['isAddition'] == true
            ? 'ADDITION TO EXISTING ORDER'
            : 'NEW ORDER',
        bold: true,
      ),
    ];
  }

  List<WindowsPrintLine> _receiptLines(
    Map<String, Object?> payload,
    String idempotencyKey,
    ReceiptPaperWidth paperWidth,
  ) {
    final currency = payload['currencyCode'] as String? ?? 'GBP';
    final summaries = aggregateReceiptPayloadLines(payload['lines']);
    final itemLines = summaries
        .map(
          (line) => WindowsPrintLine(
            '${line.name} x${line.quantity}',
            rightText: _money(line.lineTotalMinor, currency),
          ),
        )
        .toList(growable: false);
    if (itemLines.isEmpty) {
      throw const WindowsPrintQueueException(
        'The queued paid receipt does not contain any bill lines.',
      );
    }
    final tabName = payload['tabName'] as String?;
    final tableLabel = payload['tableLabel'] as String?;
    final business = payload['business'] is Map
        ? Map<Object?, Object?>.from(payload['business'] as Map)
        : const <Object?, Object?>{};
    final businessName =
        business['name'] as String? ??
        payload['restaurantName'] as String? ??
        'TABLESIDE POS';
    final addressLines = (business['address'] as String? ?? '')
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    final phoneNumbers = business['phoneNumbers'] is List
        ? (business['phoneNumbers'] as List).whereType<String>()
        : const Iterable<String>.empty();
    final lines = <WindowsPrintLine>[
      WindowsPrintLine(
        businessName,
        alignment: WindowsPrintTextAlignment.center,
        bold: true,
        fontSizeDelta: 2,
      ),
      ...addressLines.map(
        (line) => WindowsPrintLine(
          line,
          alignment: WindowsPrintTextAlignment.center,
          bold: true,
          fontSizeDelta: 1,
        ),
      ),
      ...phoneNumbers
          .take(3)
          .map(
            (number) => WindowsPrintLine(
              'Tel: ${number.trim()}',
              alignment: WindowsPrintTextAlignment.center,
              bold: true,
              fontSizeDelta: 1,
            ),
          ),
      const WindowsPrintLine(
        'PAID RECEIPT',
        alignment: WindowsPrintTextAlignment.center,
        bold: true,
      ),
      const WindowsPrintLine(''),
      WindowsPrintLine(
        'Receipt: ${payload['receiptNumber'] as String? ?? idempotencyKey}',
      ),
      if (tabName?.trim().isNotEmpty == true)
        WindowsPrintLine('Tab: ${tabName!.trim()}'),
      if (tabName?.trim().isNotEmpty != true &&
          tableLabel?.trim().isNotEmpty == true)
        WindowsPrintLine('Table: ${tableLabel!.trim()}'),
      if ((payload['businessDate'] as String?)?.trim().isNotEmpty == true)
        WindowsPrintLine('Business date: ${payload['businessDate'] as String}'),
      const WindowsPrintLine(''),
      ...itemLines,
      const WindowsPrintLine(''),
    ];
    final net = (payload['netTotalMinor'] as num?)?.toInt();
    if (net != null) {
      lines.add(WindowsPrintLine('Net', rightText: _money(net, currency)));
    }
    lines.add(
      WindowsPrintLine(
        'Tax included',
        rightText: _money(
          (payload['taxTotalMinor'] as num?)?.toInt() ?? 0,
          currency,
        ),
      ),
    );
    final rawTax = payload['taxBreakdown'];
    if (rawTax is List) {
      for (final value in rawTax.whereType<Map>()) {
        final name = value['taxRateName'] as String? ?? 'Tax';
        final amount = (value['taxMinor'] as num?)?.toInt() ?? 0;
        lines.add(WindowsPrintLine(name, rightText: _money(amount, currency)));
      }
    }
    lines.add(
      WindowsPrintLine(
        'TOTAL',
        rightText: _money(
          (payload['totalMinor'] as num?)?.toInt() ?? 0,
          currency,
        ),
        bold: true,
      ),
    );
    final rawPayments = payload['payments'];
    if (rawPayments is List && rawPayments.isNotEmpty) {
      lines.add(const WindowsPrintLine(''));
      lines.add(const WindowsPrintLine('Payments', bold: true));
      for (final value in rawPayments.whereType<Map>()) {
        final amount =
            (value['tenderedAmountMinor'] as num?)?.toInt() ??
            (value['baseAmountMinor'] as num?)?.toInt() ??
            0;
        final paymentCurrency =
            value['tenderedCurrencyCode'] as String? ?? currency;
        lines.add(
          WindowsPrintLine(
            value['method'] as String? ?? 'Payment',
            rightText: _money(amount, paymentCurrency),
          ),
        );
      }
    }
    final footer = business['receiptFooter'] as String? ?? '';
    if (footer.trim().isNotEmpty) {
      lines.add(const WindowsPrintLine(''));
      lines.add(
        WindowsPrintLine(
          footer.trim(),
          alignment: WindowsPrintTextAlignment.center,
        ),
      );
    }
    return lines;
  }

  String _money(int amountMinor, String currencyCode) {
    final sign = amountMinor < 0 ? '-' : '';
    final absolute = amountMinor.abs();
    return '$sign$currencyCode ${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
  }
}
