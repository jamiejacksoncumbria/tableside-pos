import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';

final salesReportBillsProvider = StreamProvider<List<SalesReportBill>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SalesReportBill>[]);
  return ref.watch(firestorePosRepositoryProvider).watchSalesReportBills(scope);
});

final openVenueOrdersReportProvider = StreamProvider<List<PosOrder>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <PosOrder>[]);
  return ref.watch(firestorePosRepositoryProvider).watchVenueOpenOrders(scope);
});

enum _ReportPeriod { day, week, month, custom }

class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({
    super.key,
    required this.currencyCode,
    required this.businessDayCutoffMinutes,
  });

  final String currencyCode;
  final int businessDayCutoffMinutes;

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  _ReportPeriod _period = _ReportPeriod.day;
  DateTimeRange? _customRange;
  DateTime? _anchorDate;
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final staffSession = ref.watch(activeStaffPinSessionProvider);
    if (scope == null || staffSession == null) {
      return const Center(child: Text('Select a venue to view reports.'));
    }
    final canView = staffSession.roles.any(
      (role) => role == 'owner' || role == 'manager',
    );
    if (!canView) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Only owners and managers can view financial reports.'),
        ),
      );
    }
    final report = ref.watch(salesReportBillsProvider);
    final openOrders = ref.watch(openVenueOrdersReportProvider);
    if (openOrders.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (openOrders.hasError) {
      AppLogger.error(
        'Display open-order report count',
        openOrders.error!,
        openOrders.stackTrace ?? StackTrace.current,
      );
    }
    return report.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) {
        AppLogger.error('Display sales report', error, stackTrace);
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Sales reporting could not be loaded: $error'),
          ),
        );
      },
      data: (bills) => _buildReport(bills, openOrders.value?.length ?? 0),
    );
  }

  Widget _buildReport(List<SalesReportBill> allBills, int openOrderCount) {
    final latestAnchor = allBills.isEmpty
        ? DateTime.now()
        : allBills
              .map((bill) => bill.businessDate)
              .reduce((left, right) => left.isAfter(right) ? left : right);
    final anchor = _anchorDate ?? latestAnchor;
    final bills = allBills
        .where(
          (bill) => _inPeriod(bill.businessDate, anchor, _period, _customRange),
        )
        .toList(growable: false);
    final gross = bills.fold<int>(0, (sum, bill) => sum + bill.grossMinor);
    final net = bills.fold<int>(0, (sum, bill) => sum + bill.netMinor);
    final tax = bills.fold<int>(0, (sum, bill) => sum + bill.taxMinor);
    final average = bills.isEmpty ? 0 : gross ~/ bills.length;
    final paymentTotals = <String, (String, int)>{};
    final productTotals = <String, (String, int, int)>{};
    final staffTotals = <String, int>{};
    final taxTotals = <String, (String, int, int, int, int)>{};
    for (final bill in bills) {
      final staff = bill.closedByName.trim().isEmpty
          ? 'Unknown staff member'
          : bill.closedByName.trim();
      staffTotals[staff] = (staffTotals[staff] ?? 0) + bill.grossMinor;
      for (final payment in bill.payments) {
        final method = payment.method == 'cardTerminal'
            ? 'Card${payment.terminalLabel?.trim().isNotEmpty == true ? ' · ${payment.terminalLabel}' : ''}'
            : 'Cash · ${payment.currencyCode}';
        final existing = paymentTotals[method];
        paymentTotals[method] = (
          payment.currencyCode,
          (existing?.$2 ?? 0) + payment.tenderedAmountMinor,
        );
      }
      for (final line in bill.lines) {
        final key = line.productId.isEmpty ? line.productName : line.productId;
        final existing = productTotals[key];
        productTotals[key] = (
          line.productName,
          (existing?.$2 ?? 0) + line.quantity,
          (existing?.$3 ?? 0) + line.grossMinor,
        );
      }
      for (final tax in bill.taxBreakdown) {
        final key = '${tax.name}_${tax.basisPoints}';
        final existing = taxTotals[key];
        taxTotals[key] = (
          tax.name,
          tax.basisPoints,
          (existing?.$3 ?? 0) + tax.grossMinor,
          (existing?.$4 ?? 0) + tax.netMinor,
          (existing?.$5 ?? 0) + tax.taxMinor,
        );
      }
    }
    final products = productTotals.values.toList()
      ..sort((left, right) => right.$3.compareTo(left.$3));

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Sales reports', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Closed bills only · ${_periodLabel(anchor, _period, _customRange)}',
        ),
        const SizedBox(height: 3),
        Text(
          'Venue business day ends at ${_clockLabel(widget.businessDayCutoffMinutes)}. Each bill retains the cut-off used when it closed.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<_ReportPeriod>(
              segments: const [
                ButtonSegment(value: _ReportPeriod.day, label: Text('Daily')),
                ButtonSegment(value: _ReportPeriod.week, label: Text('Weekly')),
                ButtonSegment(
                  value: _ReportPeriod.month,
                  label: Text('Monthly'),
                ),
              ],
              emptySelectionAllowed: true,
              selected: _period == _ReportPeriod.custom ? const {} : {_period},
              onSelectionChanged: (value) {
                if (value.isNotEmpty) setState(() => _period = value.first);
              },
            ),
            if (_period == _ReportPeriod.custom)
              FilledButton.icon(
                onPressed: () => _selectCustomRange(anchor, allBills),
                icon: const Icon(Icons.date_range_rounded),
                label: Text(_customRangeLabel(_customRange)),
              )
            else
              OutlinedButton.icon(
                onPressed: () => _selectCustomRange(anchor, allBills),
                icon: const Icon(Icons.date_range_rounded),
                label: const Text('Custom dates'),
              ),
            if (_period != _ReportPeriod.custom) ...[
              IconButton.filledTonal(
                tooltip: 'Previous period',
                onPressed: () => setState(
                  () => _anchorDate = _shiftPeriod(anchor, _period, -1),
                ),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton.filledTonal(
                tooltip: 'Next period',
                onPressed: _samePeriod(anchor, latestAnchor, _period)
                    ? null
                    : () => setState(
                        () => _anchorDate = _shiftPeriod(anchor, _period, 1),
                      ),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              TextButton(
                onPressed: _anchorDate == null
                    ? null
                    : () => setState(() => _anchorDate = null),
                child: const Text('Latest'),
              ),
            ],
            FilledButton.icon(
              onPressed: bills.isEmpty || _exporting
                  ? null
                  : () => _exportCsv(
                      bills,
                      _periodBounds(anchor, _period, _customRange),
                    ),
              icon: const Icon(Icons.download_rounded),
              label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Metric('Gross sales', gross, widget.currencyCode),
            _Metric('Net sales', net, widget.currencyCode),
            _Metric('Tax', tax, widget.currencyCode),
            _Metric('Average bill', average, widget.currencyCode),
            _CountMetric('Closed bills', bills.length),
            _CountMetric('Open bills', openOrderCount),
          ],
        ),
        const SizedBox(height: 18),
        _BreakdownCard(
          title: 'Payments',
          rows: paymentTotals.entries
              .map(
                (entry) => (
                  entry.key,
                  formatMoney(entry.value.$2, currencyCode: entry.value.$1),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        _BreakdownCard(
          title: 'Tax by rate',
          rows: taxTotals.values
              .map(
                (entry) => (
                  '${entry.$1} · ${(entry.$2 / 100).toStringAsFixed(2)}% · net ${formatMoney(entry.$4, currencyCode: widget.currencyCode)}',
                  formatMoney(entry.$5, currencyCode: widget.currencyCode),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        _BreakdownCard(
          title: 'Products',
          rows: products
              .take(20)
              .map(
                (item) => (
                  '${item.$1} × ${item.$2}',
                  formatMoney(item.$3, currencyCode: widget.currencyCode),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        _BreakdownCard(
          title: 'Sales closed by staff',
          rows: staffTotals.entries
              .map(
                (entry) => (
                  entry.key,
                  formatMoney(entry.value, currencyCode: widget.currencyCode),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        _BreakdownCard(
          title: 'Closed bill audit',
          rows: bills
              .map(
                (bill) => (
                  '${bill.receiptNumber} · ${_dateLabel(bill.businessDate)} · ${bill.closedByName.trim().isEmpty ? 'Unknown staff' : bill.closedByName}',
                  formatMoney(bill.grossMinor, currencyCode: bill.currencyCode),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Future<void> _selectCustomRange(
    DateTime anchor,
    List<SalesReportBill> bills,
  ) async {
    final now = DateTime.now();
    final latestAllowed = DateTime(now.year, now.month, now.day);
    final sevenYearsAgo = DateTime(
      latestAllowed.year - 7,
      latestAllowed.month,
      latestAllowed.day,
    );
    final firstRecordedDate = bills.isEmpty
        ? null
        : bills
              .map(
                (bill) => DateTime(
                  bill.businessDate.year,
                  bill.businessDate.month,
                  bill.businessDate.day,
                ),
              )
              .reduce((left, right) => left.isBefore(right) ? left : right);
    final earliestAllowed =
        firstRecordedDate != null && firstRecordedDate.isBefore(sevenYearsAgo)
        ? firstRecordedDate
        : sevenYearsAgo;
    final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
    final safeAnchor = anchorDay.isBefore(earliestAllowed)
        ? earliestAllowed
        : anchorDay.isAfter(latestAllowed)
        ? latestAllowed
        : anchorDay;
    final savedRange = _customRange;
    final initial =
        savedRange != null &&
            !savedRange.start.isBefore(earliestAllowed) &&
            !savedRange.end.isAfter(latestAllowed)
        ? savedRange
        : DateTimeRange(start: safeAnchor, end: safeAnchor);
    final selected = await showDateRangePicker(
      context: context,
      firstDate: earliestAllowed,
      lastDate: latestAllowed,
      initialDateRange: initial,
      helpText: 'Select report business dates',
      saveText: 'Show report',
    );
    if (selected == null || !mounted) return;
    setState(() {
      _customRange = selected;
      _period = _ReportPeriod.custom;
    });
  }

  Future<void> _exportCsv(
    List<SalesReportBill> bills,
    DateTimeRange range,
  ) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final csv = buildSalesReportCsv(bills, widget.currencyCode);
      final fileName =
          'tableside-sales-${_dateLabel(range.start)}-to-${_dateLabel(range.end)}.csv';
      final path = await FilePicker.saveFile(
        dialogTitle: 'Export sales report',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]),
        lockParentWindow: true,
      );
      if (!mounted || path == null) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Sales report exported',
        message:
            'Saved ${bills.length} closed bill${bills.length == 1 ? '' : 's'} to CSV.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Export sales report CSV', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not export sales report',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
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
  String baseCurrencyCode,
) {
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

String _dateLabel(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

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
  _ReportPeriod.day =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
  _ReportPeriod.week =>
    'week containing ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
  _ReportPeriod.month =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}',
  _ReportPeriod.custom => _customRangeLabel(customRange),
};

String _customRangeLabel(DateTimeRange? range) {
  if (range == null) return 'Custom dates';
  String date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  return '${date(range.start)} to ${date(range.end)}';
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.currencyCode);
  final String label;
  final int value;
  final String currencyCode;
  @override
  Widget build(BuildContext context) => _MetricCard(
    label: label,
    value: formatMoney(value, currencyCode: currencyCode),
  );
}

class _CountMetric extends StatelessWidget {
  const _CountMetric(this.label, this.value);
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) =>
      _MetricCard(label: label, value: '$value');
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(label),
          ],
        ),
      ),
    ),
  );
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.title, required this.rows});
  final String title;
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            const Text('No closed sales in this period.')
          else
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(row.$1)),
                    const SizedBox(width: 12),
                    Text(row.$2),
                  ],
                ),
              ),
        ],
      ),
    ),
  );
}
