import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'booking.dart';

final venueBookingsProvider = StreamProvider<List<VenueBooking>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const []);
  return ref.watch(firestorePosRepositoryProvider).watchBookings(scope);
});

class BookingCalendarPage extends ConsumerStatefulWidget {
  const BookingCalendarPage({super.key});

  @override
  ConsumerState<BookingCalendarPage> createState() =>
      _BookingCalendarPageState();
}

class _BookingCalendarPageState extends ConsumerState<BookingCalendarPage> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final bookingValue = ref.watch(venueBookingsProvider);
    final tables =
        ref.watch(diningTablesProvider).value ?? const <DiningTable>[];
    final bookings = (bookingValue.value ?? const <VenueBooking>[])
        .where(
          (booking) => DateUtils.isSameDay(booking.startsAt.toLocal(), _day),
        )
        .toList(growable: false);
    return Scaffold(
      floatingActionButton: scope == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _editBooking(scope: scope, tables: tables),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New booking'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bookings',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Text('Live table reservations for the selected venue.'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => setState(
                      () => _day = _day.subtract(const Duration(days: 1)),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton.icon(
                    onPressed: _pickDay,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: Text(_dateLabel(_day)),
                  ),
                  IconButton(
                    onPressed: () => setState(
                      () => _day = _day.add(const Duration(days: 1)),
                    ),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (bookingValue.isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            )
          else if (bookingValue.hasError)
            _MessageCard(
              icon: Icons.error_outline,
              text:
                  'Bookings could not be loaded. Check the debug console and Firestore deployment.',
            )
          else if (bookings.isEmpty)
            const _MessageCard(
              icon: Icons.event_available_outlined,
              text: 'No bookings for this day.',
            )
          else
            for (final booking in bookings) ...[
              _BookingCard(
                booking: booking,
                tableLabel: _tableLabel(tables, booking.tableId),
                onEdit: scope == null
                    ? null
                    : () => _editBooking(
                        scope: scope,
                        tables: tables,
                        existing: booking,
                      ),
                onStatus: scope == null
                    ? null
                    : (status) => _changeStatus(scope, booking, status),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Future<void> _pickDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 7)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 7)),
    );
    if (selected != null) setState(() => _day = selected);
  }

  Future<void> _changeStatus(
    VenueScope scope,
    VenueBooking booking,
    BookingStatus status,
  ) async {
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .saveBooking(
            scope: scope,
            bookingId: booking.id,
            tableId: booking.tableId,
            customerName: booking.customerName,
            phone: booking.phone,
            notes: booking.notes,
            guestCount: booking.guestCount,
            startsAt: booking.startsAt,
            durationMinutes: booking.durationMinutes,
            status: status.name,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Change booking status', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Booking was not updated',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    }
  }

  Future<void> _editBooking({
    required VenueScope scope,
    required List<DiningTable> tables,
    VenueBooking? existing,
  }) async {
    if (tables.isEmpty) {
      showAppNotification(
        context,
        ref: ref,
        title: 'No tables configured',
        message: 'Add venue tables before creating a booking.',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    final name = TextEditingController(text: existing?.customerName ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final guests = TextEditingController(text: '${existing?.guestCount ?? 2}');
    final duration = TextEditingController(
      text: '${existing?.durationMinutes ?? 120}',
    );
    final notes = TextEditingController(text: existing?.notes ?? '');
    var tableId = existing?.tableId ?? tables.first.id;
    var startsAt =
        existing?.startsAt.toLocal() ??
        DateTime(_day.year, _day.month, _day.day, 19);
    var status = existing?.status ?? BookingStatus.requested;
    final formKey = GlobalKey<FormState>();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(existing == null ? 'New booking' : 'Edit booking'),
            content: SizedBox(
              width: 480,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: name,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Customer name',
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone (optional)',
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: tableId,
                        decoration: const InputDecoration(labelText: 'Table'),
                        items: [
                          for (final table in tables)
                            DropdownMenuItem(
                              value: table.id,
                              child: Text(table.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => tableId = value ?? tableId),
                      ),
                      const SizedBox(height: 10),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule),
                        title: Text(
                          '${_dateLabel(startsAt)} · ${_timeLabel(startsAt)}',
                        ),
                        subtitle: const Text('Booking date and time'),
                        onTap: () async {
                          final date = await showDatePicker(
                            context: dialogContext,
                            initialDate: startsAt,
                            firstDate: DateTime.now().subtract(
                              const Duration(days: 365 * 7),
                            ),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365 * 7),
                            ),
                          );
                          if (date == null || !dialogContext.mounted) return;
                          final time = await showTimePicker(
                            context: dialogContext,
                            initialTime: TimeOfDay.fromDateTime(startsAt),
                          );
                          if (time != null) {
                            setDialogState(
                              () => startsAt = DateTime(
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              ),
                            );
                          }
                        },
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: guests,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Guests',
                              ),
                              validator: _positiveInt,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: duration,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Duration (minutes)',
                              ),
                              validator: _positiveInt,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<BookingStatus>(
                        initialValue: status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: [
                          for (final value in BookingStatus.values)
                            DropdownMenuItem(
                              value: value,
                              child: Text(value.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => status = value ?? status),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: notes,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Notes (optional)',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!(formKey.currentState?.validate() ?? false)) return;
                  try {
                    await ref
                        .read(productionCommandRepositoryProvider)
                        .saveBooking(
                          scope: scope,
                          bookingId: existing?.id,
                          tableId: tableId,
                          customerName: name.text.trim(),
                          phone: phone.text.trim(),
                          notes: notes.text.trim(),
                          guestCount: int.parse(guests.text),
                          startsAt: startsAt,
                          durationMinutes: int.parse(duration.text),
                          status: status.name,
                        );
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  } on Object catch (error, stackTrace) {
                    AppLogger.error('Save booking', error, stackTrace);
                    if (dialogContext.mounted) {
                      showAppNotification(
                        dialogContext,
                        ref: ref,
                        title: 'Could not save booking',
                        message: '$error',
                        level: AppNotificationLevel.error,
                      );
                    }
                  }
                },
                child: const Text('Save booking'),
              ),
            ],
          ),
        ),
      );
    } finally {
      name.dispose();
      phone.dispose();
      guests.dispose();
      duration.dispose();
      notes.dispose();
    }
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.booking,
    required this.tableLabel,
    required this.onEdit,
    required this.onStatus,
  });
  final VenueBooking booking;
  final String tableLabel;
  final VoidCallback? onEdit;
  final ValueChanged<BookingStatus>? onStatus;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: CircleAvatar(child: Text(_timeLabel(booking.startsAt))),
      title: Text(booking.customerName),
      subtitle: Text(
        '$tableLabel · ${booking.guestCount} guest${booking.guestCount == 1 ? '' : 's'} · ${booking.durationMinutes} min\n${booking.status.label}${booking.phone.isEmpty ? '' : ' · ${booking.phone}'}',
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<Object>(
        onSelected: (value) {
          if (value == 'edit') onEdit?.call();
          if (value is BookingStatus) onStatus?.call(value);
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit details')),
          for (final status in BookingStatus.values)
            if (status != booking.status)
              PopupMenuItem(
                value: status,
                child: Text('Mark ${status.label.toLowerCase()}'),
              ),
        ],
      ),
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

String _tableLabel(List<DiningTable> tables, String id) {
  for (final table in tables) {
    if (table.id == id) return table.label;
  }
  return 'Unknown table';
}

String _dateLabel(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
String _timeLabel(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String? _required(String? value) =>
    value == null || value.trim().isEmpty ? 'Required' : null;
String? _positiveInt(String? value) {
  final parsed = int.tryParse(value ?? '');
  return parsed == null || parsed <= 0 ? 'Enter a positive whole number' : null;
}
