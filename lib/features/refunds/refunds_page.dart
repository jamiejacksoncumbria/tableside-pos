import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../stock/stock_management_page.dart';

final refundBillsProvider = StreamProvider<List<SalesReportBill>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SalesReportBill>[]);
  return ref.watch(firestorePosRepositoryProvider).watchSalesReportBills(scope);
});

final venueRefundsProvider = StreamProvider<List<SalesReportRefund>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SalesReportRefund>[]);
  return ref
      .watch(firestorePosRepositoryProvider)
      .watchSalesReportRefunds(scope);
});

class RefundsPage extends ConsumerStatefulWidget {
  const RefundsPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<RefundsPage> createState() => _RefundsPageState();
}

class _RefundsPageState extends ConsumerState<RefundsPage> {
  final _search = TextEditingController();
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _range = DateTimeRange(
      start: DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(const Duration(days: 30)),
      end: DateTime(today.year, today.month, today.day),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bills = ref.watch(refundBillsProvider);
    final refunds = ref.watch(venueRefundsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Refunds & corrections')),
      body: bills.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Load refundable bills', error, stack);
          return Center(child: Text('Could not load closed bills: $error'));
        },
        data: (allBills) => refunds.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) {
            AppLogger.error('Load refund history', error, stack);
            return Center(child: Text('Could not load refund history: $error'));
          },
          data: (allRefunds) => _content(allBills, allRefunds),
        ),
      ),
    );
  }

  Widget _content(
    List<SalesReportBill> allBills,
    List<SalesReportRefund> allRefunds,
  ) {
    final query = _search.text.trim().toLowerCase();
    final bills =
        allBills
            .where((bill) {
              final date = DateTime(
                bill.businessDate.year,
                bill.businessDate.month,
                bill.businessDate.day,
              );
              final inRange =
                  !date.isBefore(_range.start) && !date.isAfter(_range.end);
              if (!inRange) return false;
              if (query.isEmpty) return true;
              final amount = formatMoney(
                bill.grossMinor,
                currencyCode: bill.currencyCode,
              ).toLowerCase();
              return [
                bill.receiptNumber,
                bill.tableLabel ?? '',
                bill.tabName ?? '',
                amount,
                bill.grossMinor.toString(),
              ].any((value) => value.toLowerCase().contains(query));
            })
            .toList(growable: false)
          ..sort((a, b) {
            final left = a.closedAt ?? a.businessDate;
            final right = b.closedAt ?? b.businessDate;
            return right.compareTo(left);
          });
    final refundsByBill = <String, List<SalesReportRefund>>{};
    for (final refund in allRefunds) {
      refundsByBill.putIfAbsent(refund.billId, () => []).add(refund);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Find a closed bill',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        const Text(
          'Refunds preserve the original bill, tax and exchange-rate snapshots. A fresh manager PIN is required.',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 420,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  labelText: 'Receipt, table/tab or amount',
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _chooseDates,
              icon: const Icon(Icons.date_range_rounded),
              label: Text(
                '${formatAppDate(_range.start)} – ${formatAppDate(_range.end)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '${bills.length} closed bill${bills.length == 1 ? '' : 's'} found',
        ),
        const SizedBox(height: 8),
        if (bills.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No closed bills match this search and date range.'),
            ),
          ),
        for (final bill in bills)
          _BillCard(
            bill: bill,
            refunds: refundsByBill[bill.id] ?? const [],
            onRefund: () =>
                _refundBill(bill, refundsByBill[bill.id] ?? const []),
          ),
        if (allRefunds.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Recent refund history',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          for (final refund in allRefunds.take(30))
            Card(
              child: ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: Text(
                  '${refund.refundNumber} · ${formatMoney(refund.grossMinor, currencyCode: refund.currencyCode)}',
                ),
                subtitle: Text(
                  '${formatAppDate(refund.businessDate)} · Original ${refund.originalReceiptNumber}\n${refund.reason}',
                ),
                isThreeLine: true,
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _chooseDates() async {
    final value = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 7)),
      lastDate: DateTime.now(),
      initialDateRange: _range,
    );
    if (value != null && mounted) setState(() => _range = value);
  }

  Future<void> _refundBill(
    SalesReportBill bill,
    List<SalesReportRefund> priorRefunds,
  ) async {
    final remaining = <String, int>{};
    for (final line in bill.lines) {
      final refunded = priorRefunds
          .expand((refund) => refund.lines)
          .where((item) => item.id == line.id)
          .fold<int>(0, (sum, item) => sum + item.quantity);
      remaining[line.id] = (line.quantity - refunded).clamp(0, line.quantity);
    }
    final selection = await showDialog<_RefundRequest>(
      context: context,
      builder: (_) => _RefundDialog(bill: bill, remainingByLine: remaining),
    );
    if (selection == null || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    try {
      final result = await ProductionCommandRepository().createRefund(
        scope: scope,
        billId: bill.id,
        managerPin: selection.managerPin,
        reason: selection.reason,
        lineQuantities: selection.lineQuantities,
        cardRefundConfirmed: selection.cardRefundConfirmed,
        printReceipt: selection.printReceipt,
      );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Refund recorded',
        message: 'Refund ${result.refundNumber} recorded.',
      );
      if (result.stockAdjustmentRequired) {
        final openStock = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Refund complete'),
            content: const Text(
              'Stock was not restored automatically. If returned goods can be resold, record a separate audited stock adjustment.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open stock'),
              ),
            ],
          ),
        );
        if (openStock == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  StockManagementPage(baseCurrencyCode: widget.currencyCode),
            ),
          );
        }
      }
    } on Object catch (error, stack) {
      AppLogger.error('Create financial refund', error, stack);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Refund failed',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    }
  }
}

class _BillCard extends StatelessWidget {
  const _BillCard({
    required this.bill,
    required this.refunds,
    required this.onRefund,
  });

  final SalesReportBill bill;
  final List<SalesReportRefund> refunds;
  final VoidCallback onRefund;

  @override
  Widget build(BuildContext context) {
    final refunded = refunds.fold<int>(0, (sum, item) => sum + item.grossMinor);
    final remaining = (bill.grossMinor - refunded).clamp(0, bill.grossMinor);
    final location = bill.tabName?.trim().isNotEmpty == true
        ? 'Tab ${bill.tabName}'
        : bill.tableLabel?.trim().isNotEmpty == true
        ? 'Table ${bill.tableLabel}'
        : 'No table/name';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.point_of_sale_rounded),
        title: Text(
          '${bill.receiptNumber} · ${formatMoney(bill.grossMinor, currencyCode: bill.currencyCode)}',
        ),
        subtitle: Text(
          '${formatAppDateTime(bill.closedAt ?? bill.businessDate)} · $location'
          '${refunded > 0 ? '\nRefunded ${formatMoney(refunded, currencyCode: bill.currencyCode)}' : ''}',
        ),
        isThreeLine: refunded > 0,
        trailing: FilledButton.tonal(
          onPressed: remaining > 0 ? onRefund : null,
          child: Text(remaining > 0 ? 'Refund' : 'Fully refunded'),
        ),
      ),
    );
  }
}

class _RefundRequest {
  const _RefundRequest({
    required this.lineQuantities,
    required this.reason,
    required this.managerPin,
    required this.cardRefundConfirmed,
    required this.printReceipt,
  });

  final Map<String, int> lineQuantities;
  final String reason;
  final String managerPin;
  final bool cardRefundConfirmed;
  final bool printReceipt;
}

class _RefundDialog extends StatefulWidget {
  const _RefundDialog({required this.bill, required this.remainingByLine});

  final SalesReportBill bill;
  final Map<String, int> remainingByLine;

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _reason = TextEditingController();
  final _pin = TextEditingController();
  late final Map<String, int> _selected;
  bool _cardConfirmed = false;
  bool _printReceipt = true;

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final entry in widget.remainingByLine.entries)
        if (entry.value > 0) entry.key: entry.value,
    };
  }

  @override
  void dispose() {
    _reason.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCard = widget.bill.payments.any(
      (payment) => payment.method == 'cardTerminal',
    );
    final total = widget.bill.lines.fold<int>(0, (sum, line) {
      final quantity = _selected[line.id] ?? 0;
      if (quantity <= 0 || line.quantity <= 0) return sum;
      return sum + ((line.grossMinor * quantity) ~/ line.quantity);
    });
    return AlertDialog(
      title: Text('Refund ${widget.bill.receiptNumber}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose the quantities to refund.'),
              const SizedBox(height: 8),
              for (final line in widget.bill.lines)
                if ((widget.remainingByLine[line.id] ?? 0) > 0)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.productName),
                    subtitle: Text(
                      formatMoney(
                        line.grossMinor ~/ line.quantity,
                        currencyCode: widget.bill.currencyCode,
                      ),
                    ),
                    trailing: DropdownButton<int>(
                      value: _selected[line.id] ?? 0,
                      items: [
                        for (
                          var quantity = 0;
                          quantity <= widget.remainingByLine[line.id]!;
                          quantity++
                        )
                          DropdownMenuItem(
                            value: quantity,
                            child: Text('$quantity'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _selected[line.id] = value ?? 0),
                    ),
                  ),
              const Divider(),
              Text(
                'Refund total: ${formatMoney(total, currencyCode: widget.bill.currencyCode)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                onChanged: (_) => setState(() {}),
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Mandatory reason',
                ),
              ),
              TextField(
                controller: _pin,
                onChanged: (_) => setState(() {}),
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Fresh manager PIN',
                ),
              ),
              if (hasCard)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _cardConfirmed,
                  onChanged: (value) =>
                      setState(() => _cardConfirmed = value == true),
                  title: const Text(
                    'Card refund completed on original terminal',
                  ),
                  subtitle: const Text(
                    'TableSide records the correction only after the card provider accepts it.',
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _printReceipt,
                onChanged: (value) =>
                    setState(() => _printReceipt = value == true),
                title: const Text('Print refund receipt'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              total <= 0 ||
                  _reason.text.trim().isEmpty ||
                  _pin.text.length != 6 ||
                  (hasCard && !_cardConfirmed)
              ? null
              : () => Navigator.pop(
                  context,
                  _RefundRequest(
                    lineQuantities: Map.of(_selected)
                      ..removeWhere((_, quantity) => quantity <= 0),
                    reason: _reason.text.trim(),
                    managerPin: _pin.text,
                    cardRefundConfirmed: _cardConfirmed,
                    printReceipt: _printReceipt,
                  ),
                ),
          child: const Text('Record refund'),
        ),
      ],
    );
  }
}
