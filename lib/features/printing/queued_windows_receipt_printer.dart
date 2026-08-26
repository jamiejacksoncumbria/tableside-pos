import 'native_print_worker.dart';
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
        ? _receiptLines(payload, idempotencyKey)
        : _productionLines(payload, idempotencyKey);
    await _printer.printText(
      printer: selectedPrinter,
      title: isReceipt
          ? 'TableSide paid receipt'
          : 'TableSide production ticket',
      lines: lines,
    );
  }

  List<String> _productionLines(
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
      payload['restaurantName'] as String? ?? 'TABLESIDE POS',
      payload['isAddition'] == true ? '$area ADDITION' : area,
      '',
      location,
      'Order #$reference',
      if ((payload['createdByName'] as String?)?.trim().isNotEmpty == true)
        'By: ${(payload['createdByName'] as String).trim()}',
      '',
      ...items,
      '',
      payload['isAddition'] == true
          ? 'ADDITION TO EXISTING ORDER'
          : 'NEW ORDER',
    ];
  }

  List<String> _receiptLines(
    Map<String, Object?> payload,
    String idempotencyKey,
  ) {
    final currency = payload['currencyCode'] as String? ?? 'GBP';
    final rawLines = payload['lines'];
    final itemLines = rawLines is List
        ? rawLines
              .whereType<Map>()
              .expand((line) {
                final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
                final name =
                    line['productName'] as String? ??
                    line['name'] as String? ??
                    'Item';
                final amount = (line['lineTotalMinor'] as num?)?.toInt() ?? 0;
                return ['$quantity x $name', _money(amount, currency)];
              })
              .toList(growable: false)
        : const <String>[];
    if (itemLines.isEmpty) {
      throw const WindowsPrintQueueException(
        'The queued paid receipt does not contain any bill lines.',
      );
    }
    final tabName = payload['tabName'] as String?;
    final tableLabel = payload['tableLabel'] as String?;
    final lines = <String>[
      payload['restaurantName'] as String? ?? 'TABLESIDE POS',
      'PAID RECEIPT',
      '',
      'Receipt: ${payload['receiptNumber'] as String? ?? idempotencyKey}',
      if (tabName?.trim().isNotEmpty == true) 'Tab: ${tabName!.trim()}',
      if (tabName?.trim().isNotEmpty != true &&
          tableLabel?.trim().isNotEmpty == true)
        'Table: ${tableLabel!.trim()}',
      if ((payload['businessDate'] as String?)?.trim().isNotEmpty == true)
        'Business date: ${payload['businessDate'] as String}',
      '',
      ...itemLines,
      '',
    ];
    final net = (payload['netTotalMinor'] as num?)?.toInt();
    if (net != null) lines.add('Net: ${_money(net, currency)}');
    lines.add(
      'Tax included: ${_money((payload['taxTotalMinor'] as num?)?.toInt() ?? 0, currency)}',
    );
    final rawTax = payload['taxBreakdown'];
    if (rawTax is List) {
      for (final value in rawTax.whereType<Map>()) {
        final name = value['taxRateName'] as String? ?? 'Tax';
        final amount = (value['taxMinor'] as num?)?.toInt() ?? 0;
        lines.add('$name: ${_money(amount, currency)}');
      }
    }
    lines.add(
      'TOTAL: ${_money((payload['totalMinor'] as num?)?.toInt() ?? 0, currency)}',
    );
    final rawPayments = payload['payments'];
    if (rawPayments is List && rawPayments.isNotEmpty) {
      lines.add('');
      lines.add('Payments');
      for (final value in rawPayments.whereType<Map>()) {
        final amount =
            (value['tenderedAmountMinor'] as num?)?.toInt() ??
            (value['baseAmountMinor'] as num?)?.toInt() ??
            0;
        final paymentCurrency =
            value['tenderedCurrencyCode'] as String? ?? currency;
        lines.add(
          '${value['method'] as String? ?? 'Payment'}: ${_money(amount, paymentCurrency)}',
        );
      }
    }
    return lines;
  }

  String _money(int amountMinor, String currencyCode) {
    final sign = amountMinor < 0 ? '-' : '';
    final absolute = amountMinor.abs();
    return '$sign$currencyCode ${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
  }
}
