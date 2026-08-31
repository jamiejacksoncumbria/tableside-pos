import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../bookings/booking.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import '../printing/bluetooth_receipt_printer_factory.dart';
import '../printing/windows_print_queue.dart';
import '../printing/windows_print_queue_factory.dart';

final bookingReportBookingsProvider = StreamProvider<List<VenueBooking>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <VenueBooking>[]);
  return ref.watch(firestorePosRepositoryProvider).watchBookings(scope);
});

class BookingReportPage extends ConsumerStatefulWidget {
  const BookingReportPage({super.key, required this.initialRange});

  final DateTimeRange initialRange;

  @override
  ConsumerState<BookingReportPage> createState() => _BookingReportPageState();
}

class _BookingReportPageState extends ConsumerState<BookingReportPage> {
  late DateTimeRange _range = widget.initialRange;
  bool _printing = false;

  @override
  Widget build(BuildContext context) {
    final bookingsValue = ref.watch(bookingReportBookingsProvider);
    final tables =
        ref.watch(diningTablesProvider).value ?? const <DiningTable>[];
    final bookings = (bookingsValue.value ?? const <VenueBooking>[]).where((
      booking,
    ) {
      final date = DateUtils.dateOnly(booking.startsAt.toLocal());
      return !date.isBefore(DateUtils.dateOnly(_range.start)) &&
          !date.isAfter(DateUtils.dateOnly(_range.end));
    }).toList()..sort((a, b) => a.startsAt.compareTo(b.startsAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Booking report'),
        actions: [
          IconButton(
            tooltip: 'Choose dates',
            onPressed: _chooseDates,
            icon: const Icon(Icons.date_range_rounded),
          ),
          IconButton(
            tooltip: 'Choose printer and print',
            onPressed: bookings.isEmpty || _printing
                ? null
                : () => _print(bookings, tables),
            icon: const Icon(Icons.print_outlined),
          ),
        ],
      ),
      body: bookingsValue.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '${formatAppDate(_range.start)} to ${formatAppDate(_range.end)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (bookings.isEmpty)
                  const Text('No active bookings in this date range.')
                else
                  for (final booking in bookings)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.event_seat_outlined),
                        title: Text(
                          '${formatAppDateTime(booking.startsAt.toLocal())} · ${_tableLabel(tables, booking.tableId)}',
                        ),
                        subtitle: Text(
                          '${booking.customerName} · ${booking.guestCount} guest${booking.guestCount == 1 ? '' : 's'} · ${booking.status.label}',
                        ),
                      ),
                    ),
              ],
            ),
    );
  }

  String _tableLabel(List<DiningTable> tables, String id) {
    for (final table in tables) {
      if (table.id == id) return table.label;
    }
    return 'Table unavailable';
  }

  Future<void> _chooseDates() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(DateTime.now().year - 7),
      lastDate: DateTime(DateTime.now().year + 7, 12, 31),
      initialDateRange: _range,
    );
    if (selected != null && mounted) setState(() => _range = selected);
  }

  List<String> _lines(
    List<VenueBooking> bookings,
    List<DiningTable> tables,
  ) => [
    '${formatAppDate(_range.start)} to ${formatAppDate(_range.end)}',
    '',
    for (final booking in bookings) ...[
      '${formatAppDateTime(booking.startsAt.toLocal())}  ${_tableLabel(tables, booking.tableId)}',
      '${booking.customerName}  Covers: ${booking.guestCount}',
      if (booking.phone.trim().isNotEmpty) 'Tel: ${booking.phone.trim()}',
      if (booking.notes.trim().isNotEmpty) 'Notes: ${booking.notes.trim()}',
      'Status: ${booking.status.label}',
      '',
    ],
  ];

  Future<void> _print(
    List<VenueBooking> bookings,
    List<DiningTable> tables,
  ) async {
    setState(() => _printing = true);
    try {
      final windows = createWindowsPrintQueue();
      if (windows.isSupported) {
        final printers = await windows.installedPrinters();
        if (!mounted) return;
        final selected = await showDialog<WindowsPrintQueueDevice>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose printer'),
            children: [
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
          title: 'Booking report',
          lines: _lines(bookings, tables).map(WindowsPrintLine.new).toList(),
        );
      } else {
        final bluetooth = createBluetoothReceiptPrinter();
        final printers = await bluetooth.pairedDevices();
        if (!mounted) return;
        final selected = await showDialog(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose printer'),
            children: [
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
          title: 'BOOKING REPORT',
          lines: _lines(bookings, tables),
        );
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking report sent to printer.')),
        );
    } catch (error, stackTrace) {
      AppLogger.error('Print booking report', error, stackTrace);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not print booking report: $error')),
        );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }
}
