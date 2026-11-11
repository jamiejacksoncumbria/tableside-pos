import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import '../printing/bluetooth_receipt_printer_factory.dart';
import '../printing/windows_print_queue.dart';
import '../printing/windows_print_queue_factory.dart';
import 'booking_report_page.dart';

part 'widgets/report_calculations.dart';
part 'widgets/report_metric_widgets.dart';

final salesReportBillsProvider = StreamProvider<List<SalesReportBill>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SalesReportBill>[]);
  return ref.watch(firestorePosRepositoryProvider).watchSalesReportBills(scope);
});

final salesReportRefundsProvider = StreamProvider<List<SalesReportRefund>>((
  ref,
) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SalesReportRefund>[]);
  return ref
      .watch(firestorePosRepositoryProvider)
      .watchSalesReportRefunds(scope);
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
  bool _printing = false;

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
    final refundReport = ref.watch(salesReportRefundsProvider);
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
      data: (bills) => refundReport.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) {
          AppLogger.error('Display refund report', error, stackTrace);
          return Center(
            child: Text('Refund reporting could not be loaded: $error'),
          );
        },
        data: (refunds) =>
            _buildReport(bills, refunds, openOrders.value?.length ?? 0),
      ),
    );
  }

  Widget _buildReport(
    List<SalesReportBill> allBills,
    List<SalesReportRefund> allRefunds,
    int openOrderCount,
  ) {
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
    final refunds = allRefunds
        .where(
          (refund) =>
              _inPeriod(refund.businessDate, anchor, _period, _customRange),
        )
        .toList(growable: false);
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
    final average = bills.isEmpty ? 0 : grossSales ~/ bills.length;
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
    for (final refund in refunds) {
      for (final payment in refund.payments) {
        final method = payment.method == 'cardTerminal'
            ? 'Card${payment.terminalLabel?.trim().isNotEmpty == true ? ' · ${payment.terminalLabel}' : ''}'
            : payment.method == 'voucher'
            ? 'Voucher · ${payment.currencyCode}'
            : 'Cash · ${payment.currencyCode}';
        final existing = paymentTotals[method];
        paymentTotals[method] = (
          payment.currencyCode,
          (existing?.$2 ?? 0) - payment.tenderedAmountMinor,
        );
      }
      for (final line in refund.lines) {
        final key = line.productId.isEmpty ? line.productName : line.productId;
        final existing = productTotals[key];
        productTotals[key] = (
          line.productName,
          (existing?.$2 ?? 0) - line.quantity,
          (existing?.$3 ?? 0) - line.grossMinor,
        );
      }
      for (final refundTax in refund.taxBreakdown) {
        final key = '${refundTax.name}_${refundTax.basisPoints}';
        final existing = taxTotals[key];
        taxTotals[key] = (
          refundTax.name,
          refundTax.basisPoints,
          (existing?.$3 ?? 0) - refundTax.grossMinor,
          (existing?.$4 ?? 0) - refundTax.netMinor,
          (existing?.$5 ?? 0) - refundTax.taxMinor,
        );
      }
    }
    final products = productTotals.values.toList()
      ..sort((left, right) => right.$3.compareTo(left.$3));
    final reportRange = _periodBounds(anchor, _period, _customRange);
    final reportComplete = isSalesReportPeriodComplete(
      reportRange,
      widget.businessDayCutoffMinutes,
      DateTime.now(),
    );
    final incompleteMessage = _period == _ReportPeriod.day
        ? 'Day not completed yet'
        : 'Reporting period not completed yet';
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
        if (!reportComplete) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: Text(incompleteMessage),
              subtitle: Text(
                'Figures include closed bills so far. This business period completes after ${_clockLabel(widget.businessDayCutoffMinutes)}.',
              ),
            ),
          ),
        ],
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
                      refunds,
                      _periodBounds(anchor, _period, _customRange),
                    ),
              icon: const Icon(Icons.download_rounded),
              label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
            ),
            OutlinedButton.icon(
              onPressed: _printing
                  ? null
                  : () => _printSalesReport(
                      bills: bills,
                      refunds: refunds,
                      openOrderCount: openOrderCount,
                      range: reportRange,
                      reportComplete: reportComplete,
                    ),
              icon: const Icon(Icons.print_outlined),
              label: Text(_printing ? 'Printing…' : 'Print report'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            leading: const Icon(Icons.event_note_rounded),
            title: const Text('Upcoming booking report'),
            subtitle: const Text(
              'Choose dates, review the report, then select a local printer.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _openBookingReport,
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Metric('Gross sales', grossSales, widget.currencyCode),
            _Metric('Refunds', -refundGross, widget.currencyCode),
            _Metric('Sales after refunds', gross, widget.currencyCode),
            _Metric('Net sales', net, widget.currencyCode),
            _Metric('Tax', tax, widget.currencyCode),
            _Metric('Average bill', average, widget.currencyCode),
            _CountMetric('Closed bills', bills.length),
            _CountMetric('Refund transactions', refunds.length),
            _CountMetric('Open bills', openOrderCount),
          ],
        ),
        const SizedBox(height: 18),
        _BreakdownCard(
          title: 'Refund audit',
          rows: refunds
              .map(
                (refund) => (
                  '${refund.refundNumber} · original ${refund.originalReceiptNumber} · ${refund.refundedByName.isEmpty ? 'Unknown manager' : refund.refundedByName}',
                  formatMoney(
                    -refund.grossMinor,
                    currencyCode: refund.currencyCode,
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
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

  Future<void> _openBookingReport() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: DateTime(today.year + 7, today.month, today.day),
      initialDateRange: DateTimeRange(
        start: today,
        end: today.add(const Duration(days: 30)),
      ),
      helpText: 'Upcoming booking dates',
      saveText: 'Show bookings',
    );
    if (selected != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BookingReportPage(initialRange: selected),
        ),
      );
    }
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
    List<SalesReportRefund> refunds,
    DateTimeRange range,
  ) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final csv = buildSalesReportCsv(bills, widget.currencyCode, refunds);
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

  Future<void> _printSalesReport({
    required List<SalesReportBill> bills,
    required List<SalesReportRefund> refunds,
    required int openOrderCount,
    required DateTimeRange range,
    required bool reportComplete,
  }) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final profile = ref.read(tenantProfileProvider);
      final lines = buildSalesReportPrintLines(
        bills: bills,
        refunds: refunds,
        openOrderCount: openOrderCount,
        range: range,
        currencyCode: widget.currencyCode,
        cutoffMinutes: widget.businessDayCutoffMinutes,
        reportComplete: reportComplete,
      );
      final title = '${profile.displayName} SALES REPORT';
      final windows = createWindowsPrintQueue();
      if (windows.isSupported) {
        final printers = await windows.installedPrinters();
        if (!mounted) return;
        final selected = await showAppDialog<WindowsPrintQueueDevice>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose report printer'),
            children: [
              if (printers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No installed Windows printers were found.'),
                ),
              for (final printer in printers)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, printer),
                  child: Text(printer.name),
                ),
            ],
          ),
        );
        if (selected == null) return;
        await windows.printText(
          printer: selected,
          title: title,
          lines: lines.map(WindowsPrintLine.new).toList(growable: false),
        );
      } else {
        final bluetooth = createBluetoothReceiptPrinter();
        if (!bluetooth.isSupported) {
          throw StateError(
            'Direct report printing is available from Android and Windows. Use the browser print command on web.',
          );
        }
        final printers = await bluetooth.pairedDevices();
        if (!mounted) return;
        final selected = await showAppDialog(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose report printer'),
            children: [
              if (printers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No paired Bluetooth printers were found.'),
                ),
              for (final printer in printers)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, printer),
                  child: Text(printer.name),
                ),
            ],
          ),
        );
        if (selected == null) return;
        await bluetooth.printTextReport(
          device: selected,
          title: title,
          lines: lines,
        );
      }
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Sales report sent to printer',
        message: reportComplete
            ? 'The completed report was sent to the selected printer.'
            : 'The report was printed and clearly marked as not completed.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Print sales report', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not print sales report',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }
}
