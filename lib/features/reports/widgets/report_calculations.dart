part of '../reports_page.dart';

bool isSalesReportPeriodComplete(
  DateTimeRange range,
  int cutoffMinutes,
  DateTime now,
) {
  final safeCutoff = cutoffMinutes.clamp(0, 1439);
  var currentBusinessDate = DateTime(now.year, now.month, now.day);
  if ((now.hour * 60) + now.minute < safeCutoff) {
    currentBusinessDate = currentBusinessDate.subtract(const Duration(days: 1));
  }
  final end = DateTime(range.end.year, range.end.month, range.end.day);
  return end.isBefore(currentBusinessDate);
}

List<String> buildSalesReportPrintLines({
  required List<SalesReportBill> bills,
  List<SalesReportRefund> refunds = const [],
  required int openOrderCount,
  required DateTimeRange range,
  required String currencyCode,
  required int cutoffMinutes,
  required bool reportComplete,
}) {
  final grossSales = bills.fold<int>(0, (sum, bill) => sum + bill.grossMinor);
  final refundGross = refunds.fold<int>(
    0,
    (sum, item) => sum + item.grossMinor,
  );
  final gross = grossSales - refundGross;
  final net =
      bills.fold<int>(0, (sum, bill) => sum + bill.netMinor) -
      refunds.fold<int>(0, (sum, item) => sum + item.netMinor);
  final tax =
      bills.fold<int>(0, (sum, bill) => sum + bill.taxMinor) -
      refunds.fold<int>(0, (sum, item) => sum + item.taxMinor);
  final payments = <String, (String, int)>{};
  final products = <String, (String, int, int)>{};
  final staff = <String, int>{};
  for (final bill in bills) {
    final staffName = bill.closedByName.trim().isEmpty
        ? 'Unknown staff'
        : bill.closedByName.trim();
    staff[staffName] = (staff[staffName] ?? 0) + bill.grossMinor;
    for (final payment in bill.payments) {
      final label = payment.method == 'cardTerminal'
          ? 'Card${payment.terminalLabel?.trim().isNotEmpty == true ? ' - ${payment.terminalLabel!.trim()}' : ''}'
          : 'Cash ${payment.currencyCode}';
      final existing = payments[label];
      payments[label] = (
        payment.currencyCode,
        (existing?.$2 ?? 0) + payment.tenderedAmountMinor,
      );
    }
    for (final line in bill.lines) {
      final key = line.productId.isEmpty ? line.productName : line.productId;
      final existing = products[key];
      products[key] = (
        line.productName,
        (existing?.$2 ?? 0) + line.quantity,
        (existing?.$3 ?? 0) + line.grossMinor,
      );
    }
  }
  for (final refund in refunds) {
    for (final payment in refund.payments) {
      final label = payment.method == 'cardTerminal'
          ? 'Card${payment.terminalLabel?.trim().isNotEmpty == true ? ' - ${payment.terminalLabel!.trim()}' : ''}'
          : payment.method == 'voucher'
          ? 'Voucher ${payment.currencyCode}'
          : 'Cash ${payment.currencyCode}';
      final existing = payments[label];
      payments[label] = (
        payment.currencyCode,
        (existing?.$2 ?? 0) - payment.tenderedAmountMinor,
      );
    }
    for (final line in refund.lines) {
      final key = line.productId.isEmpty ? line.productName : line.productId;
      final existing = products[key];
      products[key] = (
        line.productName,
        (existing?.$2 ?? 0) - line.quantity,
        (existing?.$3 ?? 0) - line.grossMinor,
      );
    }
  }
  final sortedProducts = products.values.toList()
    ..sort((left, right) => right.$3.compareTo(left.$3));
  return <String>[
    '${formatAppDate(range.start)} to ${formatAppDate(range.end)}',
    reportComplete ? 'PERIOD COMPLETED' : 'DAY / PERIOD NOT COMPLETED YET',
    'Business day cut-off: ${_clockLabel(cutoffMinutes)}',
    'Closed bills only',
    '',
    'Gross sales: ${formatMoney(grossSales, currencyCode: currencyCode)}',
    'Refunds: ${formatMoney(-refundGross, currencyCode: currencyCode)}',
    'Sales after refunds: ${formatMoney(gross, currencyCode: currencyCode)}',
    'Net: ${formatMoney(net, currencyCode: currencyCode)}',
    'Tax: ${formatMoney(tax, currencyCode: currencyCode)}',
    'Closed bills: ${bills.length}',
    'Refund transactions: ${refunds.length}',
    'Open bills: $openOrderCount',
    '',
    'PAYMENTS',
    if (payments.isEmpty) 'No closed payments',
    for (final entry in payments.entries)
      '${entry.key}: ${formatMoney(entry.value.$2, currencyCode: entry.value.$1)}',
    '',
    'PRODUCTS',
    if (sortedProducts.isEmpty) 'No closed product sales',
    for (final item in sortedProducts.take(30))
      '${item.$1} x${item.$2}: ${formatMoney(item.$3, currencyCode: currencyCode)}',
    '',
    'SALES CLOSED BY STAFF',
    if (staff.isEmpty) 'No closed staff sales',
    for (final entry in staff.entries)
      '${entry.key}: ${formatMoney(entry.value, currencyCode: currencyCode)}',
    '',
    'REFUNDS',
    if (refunds.isEmpty) 'No refunds',
    for (final refund in refunds)
      '${refund.refundNumber} / ${refund.originalReceiptNumber}: ${formatMoney(-refund.grossMinor, currencyCode: refund.currencyCode)} - ${refund.reason}',
    '',
    'Printed: ${formatAppDateTime(DateTime.now())}',
  ];
}

DateTimeRange _periodBounds(
  DateTime anchor,
  _ReportPeriod period,
  DateTimeRange? customRange,
) => switch (period) {
  _ReportPeriod.day => DateTimeRange(start: anchor, end: anchor),
  _ReportPeriod.week => DateTimeRange(
    start: _weekStart(anchor),
    end: _weekStart(anchor).add(const Duration(days: 6)),
  ),
  _ReportPeriod.month => DateTimeRange(
    start: DateTime(anchor.year, anchor.month, 1),
    end: DateTime(anchor.year, anchor.month + 1, 0),
  ),
  _ReportPeriod.custom =>
    customRange ?? DateTimeRange(start: anchor, end: anchor),
};

String buildSalesReportCsv(
  List<SalesReportBill> bills,
  String baseCurrencyCode, [
  List<SalesReportRefund> refunds = const [],
]) {
  const headers = <String>[
    'record_type',
    'business_date',
    'receipt_number',
    'closed_by',
    'currency',
    'gross_amount',
    'net_amount',
    'tax_amount',
    'payment_method',
    'payment_currency',
    'payment_tendered_amount',
    'payment_base_amount',
    'terminal',
    'product_id',
    'product_name',
    'quantity',
    'line_gross_amount',
    'tax_rate_name',
    'tax_rate_percent',
    'tax_rate_gross_amount',
    'tax_rate_net_amount',
    'tax_rate_tax_amount',
    'original_receipt_number',
    'reason',
  ];
  final rows = <List<Object?>>[headers];
  for (final bill in bills) {
    final common = <String, Object?>{
      'business_date': _dateLabel(bill.businessDate),
      'receipt_number': bill.receiptNumber,
      'closed_by': bill.closedByName,
      'currency': bill.currencyCode,
    };
    rows.add(
      _csvRow(headers, {
        ...common,
        'record_type': 'BILL',
        'gross_amount': _decimalAmount(bill.grossMinor, bill.currencyCode),
        'net_amount': _decimalAmount(bill.netMinor, bill.currencyCode),
        'tax_amount': _decimalAmount(bill.taxMinor, bill.currencyCode),
      }),
    );
    for (final payment in bill.payments) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'PAYMENT',
          'payment_method': payment.method,
          'payment_currency': payment.currencyCode,
          'payment_tendered_amount': _decimalAmount(
            payment.tenderedAmountMinor,
            payment.currencyCode,
          ),
          'payment_base_amount': _decimalAmount(
            payment.baseAmountMinor,
            baseCurrencyCode,
          ),
          'terminal': payment.terminalLabel,
        }),
      );
    }
    for (final line in bill.lines) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'ITEM',
          'product_id': line.productId,
          'product_name': line.productName,
          'quantity': line.quantity,
          'line_gross_amount': _decimalAmount(
            line.grossMinor,
            bill.currencyCode,
          ),
        }),
      );
    }
    for (final tax in bill.taxBreakdown) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'TAX',
          'tax_rate_name': tax.name,
          'tax_rate_percent': (tax.basisPoints / 100).toStringAsFixed(2),
          'tax_rate_gross_amount': _decimalAmount(
            tax.grossMinor,
            bill.currencyCode,
          ),
          'tax_rate_net_amount': _decimalAmount(
            tax.netMinor,
            bill.currencyCode,
          ),
          'tax_rate_tax_amount': _decimalAmount(
            tax.taxMinor,
            bill.currencyCode,
          ),
        }),
      );
    }
  }
  for (final refund in refunds) {
    final common = <String, Object?>{
      'business_date': _dateLabel(refund.businessDate),
      'receipt_number': refund.refundNumber,
      'original_receipt_number': refund.originalReceiptNumber,
      'reason': refund.reason,
      'closed_by': refund.refundedByName,
      'currency': refund.currencyCode,
    };
    rows.add(
      _csvRow(headers, {
        ...common,
        'record_type': 'REFUND',
        'gross_amount': _decimalAmount(-refund.grossMinor, refund.currencyCode),
        'net_amount': _decimalAmount(-refund.netMinor, refund.currencyCode),
        'tax_amount': _decimalAmount(-refund.taxMinor, refund.currencyCode),
      }),
    );
    for (final payment in refund.payments) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'REFUND_PAYMENT',
          'payment_method': payment.method,
          'payment_currency': payment.currencyCode,
          'payment_tendered_amount': _decimalAmount(
            -payment.tenderedAmountMinor,
            payment.currencyCode,
          ),
          'payment_base_amount': _decimalAmount(
            -payment.baseAmountMinor,
            baseCurrencyCode,
          ),
          'terminal': payment.terminalLabel,
        }),
      );
    }
    for (final line in refund.lines) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'REFUND_ITEM',
          'product_id': line.productId,
          'product_name': line.productName,
          'quantity': -line.quantity,
          'line_gross_amount': _decimalAmount(
            -line.grossMinor,
            refund.currencyCode,
          ),
        }),
      );
    }
    for (final taxEntry in refund.taxBreakdown) {
      rows.add(
        _csvRow(headers, {
          ...common,
          'record_type': 'REFUND_TAX',
          'tax_rate_name': taxEntry.name,
          'tax_rate_percent': (taxEntry.basisPoints / 100).toStringAsFixed(2),
          'tax_rate_gross_amount': _decimalAmount(
            -taxEntry.grossMinor,
            refund.currencyCode,
          ),
          'tax_rate_net_amount': _decimalAmount(
            -taxEntry.netMinor,
            refund.currencyCode,
          ),
          'tax_rate_tax_amount': _decimalAmount(
            -taxEntry.taxMinor,
            refund.currencyCode,
          ),
        }),
      );
    }
  }
  return rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');
}

List<Object?> _csvRow(List<String> headers, Map<String, Object?> values) =>
    headers.map((header) => values[header]).toList(growable: false);

String _csvCell(Object? value) {
  final text = value?.toString() ?? '';
  if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}

String _decimalAmount(int minorUnits, String currencyCode) {
  final digits = currencyDecimalDigits(currencyCode.trim().toUpperCase());
  if (digits == 0) return '$minorUnits';
  final negative = minorUnits.isNegative;
  final absolute = minorUnits.abs();
  var scale = 1;
  for (var index = 0; index < digits; index++) {
    scale *= 10;
  }
  final amount =
      '${absolute ~/ scale}.${(absolute % scale).toString().padLeft(digits, '0')}';
  return negative ? '-$amount' : amount;
}

DateTime _shiftPeriod(DateTime anchor, _ReportPeriod period, int direction) =>
    switch (period) {
      _ReportPeriod.day => anchor.add(Duration(days: direction)),
      _ReportPeriod.week => anchor.add(Duration(days: 7 * direction)),
      _ReportPeriod.month => DateTime(anchor.year, anchor.month + direction, 1),
      _ReportPeriod.custom => anchor,
    };

bool _samePeriod(DateTime left, DateTime right, _ReportPeriod period) =>
    switch (period) {
      _ReportPeriod.day =>
        left.year == right.year &&
            left.month == right.month &&
            left.day == right.day,
      _ReportPeriod.week => _weekStart(left) == _weekStart(right),
      _ReportPeriod.month =>
        left.year == right.year && left.month == right.month,
      _ReportPeriod.custom => true,
    };

DateTime _weekStart(DateTime value) {
  final day = DateTime(value.year, value.month, value.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

String _dateLabel(DateTime value) => formatAppDate(value);

String _clockLabel(int minutes) {
  final safe = minutes.clamp(0, 1439);
  return '${(safe ~/ 60).toString().padLeft(2, '0')}:${(safe % 60).toString().padLeft(2, '0')}';
}

bool _inPeriod(
  DateTime value,
  DateTime anchor,
  _ReportPeriod period,
  DateTimeRange? customRange,
) {
  if (period == _ReportPeriod.custom) {
    if (customRange == null) return false;
    final day = DateTime(value.year, value.month, value.day);
    final start = DateTime(
      customRange.start.year,
      customRange.start.month,
      customRange.start.day,
    );
    final endExclusive = DateTime(
      customRange.end.year,
      customRange.end.month,
      customRange.end.day,
    ).add(const Duration(days: 1));
    return !day.isBefore(start) && day.isBefore(endExclusive);
  }
  if (period == _ReportPeriod.day) {
    return value.year == anchor.year &&
        value.month == anchor.month &&
        value.day == anchor.day;
  }
  if (period == _ReportPeriod.month) {
    return value.year == anchor.year && value.month == anchor.month;
  }
  final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
  final weekStart = anchorDay.subtract(Duration(days: anchorDay.weekday - 1));
  final nextWeek = weekStart.add(const Duration(days: 7));
  return !value.isBefore(weekStart) && value.isBefore(nextWeek);
}

String _periodLabel(
  DateTime date,
  _ReportPeriod period,
  DateTimeRange? customRange,
) => switch (period) {
  _ReportPeriod.day => formatAppDate(date),
  _ReportPeriod.week => 'week containing ${formatAppDate(date)}',
  _ReportPeriod.month => formatAppDate(DateTime(date.year, date.month)),
  _ReportPeriod.custom => _customRangeLabel(customRange),
};

String _customRangeLabel(DateTimeRange? range) {
  if (range == null) return 'Custom dates';
  return '${formatAppDate(range.start)} to ${formatAppDate(range.end)}';
}
