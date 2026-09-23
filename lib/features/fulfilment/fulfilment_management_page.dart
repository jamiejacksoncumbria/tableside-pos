import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/printer_device_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../auth/staff_pin_gate.dart';
import '../pos/domain.dart';
import 'customer_editor.dart';
import 'fulfilment_domain.dart';
import 'fulfilment_repository.dart';

class FulfilmentManagementPage extends ConsumerStatefulWidget {
  const FulfilmentManagementPage({required this.venue, super.key});

  final Venue venue;

  @override
  ConsumerState<FulfilmentManagementPage> createState() =>
      _FulfilmentManagementPageState();
}

class _FulfilmentManagementPageState
    extends ConsumerState<FulfilmentManagementPage> {
  VenueScope get _scope => ref.read(activeVenueScopeProvider)!;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Collection, delivery & courses'),
        bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.storefront_outlined), text: 'Channels'),
            Tab(icon: Icon(Icons.room_service_outlined), text: 'Courses'),
            Tab(icon: Icon(Icons.people_outline), text: 'Customers'),
            Tab(
              icon: Icon(Icons.delivery_dining_outlined),
              text: 'Live orders',
            ),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          _ChannelsTab(scope: _scope, venue: widget.venue),
          _CoursesTab(scope: _scope),
          _CustomersTab(scope: _scope),
          _FulfilmentOrdersTab(scope: _scope),
        ],
      ),
    ),
  );
}

class _FulfilmentOrdersTab extends ConsumerWidget {
  const _FulfilmentOrdersTab({required this.scope, this.assignedDriverId});
  final VenueScope scope;
  final String? assignedDriverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(fulfilmentOrdersProvider);
    final session = ref.watch(activeStaffPinSessionProvider);
    final canAssignDrivers =
        session?.roles.any((role) => role == 'owner' || role == 'manager') ??
        false;
    final staff = canAssignDrivers
        ? ref.watch(fulfilmentStaffProvider).value ??
              const <FulfilmentStaffMember>[]
        : const <FulfilmentStaffMember>[];
    final drivers = staff
        .where((item) => item.roles.contains('driver'))
        .toList();
    return orders.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) {
        AppLogger.error('Load fulfilment orders', error, stack);
        return Center(child: Text('Live orders could not be loaded: $error'));
      },
      data: (allItems) {
        final items = assignedDriverId == null
            ? allItems
            : allItems
                  .where((order) => order.assignedDriverId == assignedDriverId)
                  .toList(growable: false);
        return items.isEmpty
            ? const Center(
                child: Text('No active collection or delivery orders.'),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final order = items[index];
                  final scheduled = order.scheduledFor;
                  final when = scheduled == null
                      ? 'ASAP'
                      : '${scheduled.day.toString().padLeft(2, '0')}-${scheduled.month.toString().padLeft(2, '0')}-${scheduled.year} ${scheduled.hour.toString().padLeft(2, '0')}:${scheduled.minute.toString().padLeft(2, '0')}';
                  final driverDeclined =
                      order.fulfilmentStatus == FulfilmentStatus.driverDeclined;
                  final driverAssigned =
                      order.fulfilmentStatus == FulfilmentStatus.assigned;
                  return Card(
                    color: driverDeclined
                        ? Colors.purple.shade100
                        : driverAssigned
                        ? Colors.green.shade100
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Chip(
                                avatar: Icon(
                                  order.channel == OrderChannel.delivery
                                      ? Icons.delivery_dining
                                      : Icons.shopping_bag_outlined,
                                ),
                                label: Text(order.channel.label),
                              ),
                              Text(
                                order.customerName ?? 'Customer',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Chip(
                                label: Text(
                                  _statusLabel(order.fulfilmentStatus),
                                ),
                              ),
                              Text(when),
                            ],
                          ),
                          if (order.customerPhone?.isNotEmpty == true)
                            Text(order.customerPhone!),
                          if (order.deliveryAddress?.isNotEmpty == true)
                            Text(order.deliveryAddress!),
                          if (order.assignedDriverName?.isNotEmpty == true)
                            Text('Driver: ${order.assignedDriverName}'),
                          if (driverDeclined)
                            const Text(
                              'Driver declined — choose another driver.',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (order.channel == OrderChannel.delivery &&
                                  canAssignDrivers)
                                OutlinedButton.icon(
                                  onPressed:
                                      !canAssignDrivers || drivers.isEmpty
                                      ? null
                                      : () => _chooseDriver(
                                          context,
                                          ref,
                                          order,
                                          drivers,
                                        ),
                                  icon: const Icon(
                                    Icons.person_pin_circle_outlined,
                                  ),
                                  label: Text(
                                    order.assignedDriverId == null
                                        ? 'Assign driver'
                                        : 'Change driver',
                                  ),
                                ),
                              if (order.channel == OrderChannel.delivery ||
                                  order.fulfilmentStatus ==
                                      FulfilmentStatus.readyForCollection ||
                                  order.fulfilmentStatus ==
                                      FulfilmentStatus.outForDelivery)
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      _printDeliveryNote(context, ref, order),
                                  icon: const Icon(Icons.print_outlined),
                                  label: Text(
                                    order.channel == OrderChannel.delivery
                                        ? 'Driver ticket'
                                        : 'Collection note',
                                  ),
                                ),
                              if (assignedDriverId != null &&
                                  order.fulfilmentStatus ==
                                      FulfilmentStatus.assigned)
                                FilledButton.tonalIcon(
                                  onPressed: () => _updateStatus(
                                    context,
                                    ref,
                                    order,
                                    FulfilmentStatus.driverDeclined,
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                  label: const Text('Decline delivery'),
                                ),
                              for (final next in _nextStatuses(order))
                                FilledButton.tonal(
                                  onPressed: () =>
                                      _updateStatus(context, ref, order, next),
                                  child: Text(_statusLabel(next)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
      },
    );
  }

  Future<void> _chooseDriver(
    BuildContext context,
    WidgetRef ref,
    PosOrder order,
    List<FulfilmentStaffMember> drivers,
  ) async {
    final driver = await showAppDialog<FulfilmentStaffMember>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Assign delivery driver'),
        children: [
          for (final item in drivers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, item),
              child: ListTile(
                leading: const Icon(Icons.delivery_dining),
                title: Text(item.name),
              ),
            ),
        ],
      ),
    );
    if (driver == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref
          .read(fulfilmentRepositoryProvider)
          .updateFulfilmentOrder(
            scope: scope,
            orderId: order.id,
            status: FulfilmentStatus.assigned,
            driverId: driver.id,
          ),
    );
  }

  Future<void> _updateStatus(
    BuildContext context,
    WidgetRef ref,
    PosOrder order,
    FulfilmentStatus status,
  ) => _run(
    context,
    ref,
    () => ref
        .read(fulfilmentRepositoryProvider)
        .updateFulfilmentOrder(scope: scope, orderId: order.id, status: status),
  );

  Future<void> _printDeliveryNote(
    BuildContext context,
    WidgetRef ref,
    PosOrder order,
  ) async {
    try {
      final devices = await PrinterDeviceRepository(FirebaseFirestore.instance)
          .watchVenueDevices(tenantId: scope.tenantId, venueId: scope.venueId)
          .first
          .timeout(const Duration(seconds: 10));
      if (!context.mounted) return;
      final printers = devices
          .where(
            (device) =>
                device.active && device.productionAreas.contains('receipt'),
          )
          .toList(growable: false);
      if (printers.isEmpty) {
        throw StateError('No active receipt printer is registered here.');
      }
      final selected = await showAppDialog<PrinterDevice>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Print delivery note'),
          children: [
            for (final printer in printers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, printer),
                child: ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: Text(printer.name),
                  subtitle: Text(printer.platform),
                ),
              ),
          ],
        ),
      );
      if (selected == null || !context.mounted) return;
      await ref
          .read(productionCommandRepositoryProvider)
          .printFulfilmentDeliveryNote(
            scope: scope,
            orderId: order.id,
            targetDeviceId: selected.id,
          );
      if (!context.mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Delivery note queued',
        message: 'The note was sent to ${selected.name}.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Print fulfilment delivery note', error, stackTrace);
      if (!context.mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not print delivery note',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error, stack) {
      AppLogger.error('Update fulfilment order', error, stack);
      if (context.mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Order was not updated',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    }
  }

  static List<FulfilmentStatus> _nextStatuses(PosOrder order) =>
      switch (order.fulfilmentStatus) {
        FulfilmentStatus.awaitingPreparation => [
          order.channel == OrderChannel.delivery
              ? FulfilmentStatus.awaitingDriver
              : FulfilmentStatus.readyForCollection,
        ],
        FulfilmentStatus.awaitingDriver => const [
          FulfilmentStatus.readyForCollection,
        ],
        FulfilmentStatus.assigned => const [
          FulfilmentStatus.readyForCollection,
        ],
        FulfilmentStatus.driverDeclined => const [],
        FulfilmentStatus.readyForCollection => [
          order.channel == OrderChannel.delivery
              ? FulfilmentStatus.outForDelivery
              : FulfilmentStatus.collected,
        ],
        FulfilmentStatus.outForDelivery => const [FulfilmentStatus.delivered],
        _ => const [],
      };

  static String _statusLabel(FulfilmentStatus status) => switch (status) {
    FulfilmentStatus.awaitingPreparation => 'Preparing',
    FulfilmentStatus.readyForCollection => 'Ready',
    FulfilmentStatus.awaitingDriver => 'Awaiting driver',
    FulfilmentStatus.assigned => 'Driver assigned',
    FulfilmentStatus.driverDeclined => 'Driver declined',
    FulfilmentStatus.outForDelivery => 'Out for delivery',
    FulfilmentStatus.collected => 'Collected',
    FulfilmentStatus.delivered => 'Delivered',
    FulfilmentStatus.cancelled => 'Cancelled',
  };
}

class FulfilmentOperationsPage extends ConsumerWidget {
  const FulfilmentOperationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    final session = ref.watch(activeStaffPinSessionProvider);
    if (scope == null || session == null) {
      return const Center(
        child: Text('Select a venue and staff member first.'),
      );
    }
    final driverOnly =
        session.roles.contains('driver') &&
        !session.roles.any((role) => role == 'owner' || role == 'manager');
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text(
              driverOnly ? 'My deliveries' : 'Collection & delivery',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Expanded(
            child: _FulfilmentOrdersTab(
              scope: scope,
              assignedDriverId: driverOnly ? session.userId : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelsTab extends ConsumerStatefulWidget {
  const _ChannelsTab({required this.scope, required this.venue});

  final VenueScope scope;
  final Venue venue;

  @override
  ConsumerState<_ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends ConsumerState<_ChannelsTab> {
  VenueFulfilmentSettings? _draft;
  bool _saving = false;

  VenueFulfilmentSettings _copy(
    VenueFulfilmentSettings current, {
    bool? collectionEnabled,
    bool? deliveryEnabled,
    bool? courseControlEnabled,
    int? collectionLeadMinutes,
    int? deliveryLeadMinutes,
    List<ServiceWindow>? collectionWindows,
    List<ServiceWindow>? deliveryWindows,
    List<ServiceArea>? serviceAreas,
    List<ServiceDateOverride>? dateOverrides,
  }) => VenueFulfilmentSettings(
    collectionEnabled: collectionEnabled ?? current.collectionEnabled,
    deliveryEnabled: deliveryEnabled ?? current.deliveryEnabled,
    courseControlEnabled: courseControlEnabled ?? current.courseControlEnabled,
    collectionLeadMinutes:
        collectionLeadMinutes ?? current.collectionLeadMinutes,
    deliveryLeadMinutes: deliveryLeadMinutes ?? current.deliveryLeadMinutes,
    collectionWindows: collectionWindows ?? current.collectionWindows,
    deliveryWindows: deliveryWindows ?? current.deliveryWindows,
    serviceAreas: serviceAreas ?? current.serviceAreas,
    dateOverrides: dateOverrides ?? current.dateOverrides,
  );

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(venueFulfilmentSettingsProvider);
    return remote.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) {
        AppLogger.error('Load fulfilment settings', error, stack);
        return Center(child: Text('Settings could not be loaded: $error'));
      },
      data: (settings) {
        final draft = _draft ?? settings;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SwitchListTile.adaptive(
              value: draft.collectionEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(
                      () => _draft = _copy(draft, collectionEnabled: value),
                    ),
              title: const Text('Collection / takeaway'),
              subtitle: const Text('Allow collection orders at this venue.'),
            ),
            SwitchListTile.adaptive(
              value: draft.deliveryEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(
                      () => _draft = _copy(draft, deliveryEnabled: value),
                    ),
              title: const Text('Delivery'),
              subtitle: const Text(
                'Allow delivery orders and driver assignment.',
              ),
            ),
            SwitchListTile.adaptive(
              value: draft.courseControlEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(
                      () => _draft = _copy(draft, courseControlEnabled: value),
                    ),
              title: const Text('Course release control'),
              subtitle: const Text(
                'Existing products remain Standard / immediate.',
              ),
            ),
            const Divider(height: 32),
            Text(
              'Preparation lead times',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'A future order stays purple and its kitchen timer does not start until this many minutes before the promised time.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: draft.collectionLeadMinutes,
              decoration: const InputDecoration(
                labelText: 'Collection lead time',
                suffixText: 'minutes',
              ),
              items: [
                for (var minutes = 5; minutes <= 120; minutes += 5)
                  DropdownMenuItem(value: minutes, child: Text('$minutes')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(
                      () => _draft = _copy(draft, collectionLeadMinutes: value),
                    ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: draft.deliveryLeadMinutes,
              decoration: const InputDecoration(
                labelText: 'Delivery lead time',
                suffixText: 'minutes',
              ),
              items: [
                for (var minutes = 5; minutes <= 120; minutes += 5)
                  DropdownMenuItem(value: minutes, child: Text('$minutes')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(
                      () => _draft = _copy(draft, deliveryLeadMinutes: value),
                    ),
            ),
            const Divider(height: 32),
            _SettingsHeading(
              title: 'Collection hours',
              actionLabel: 'Add window',
              onPressed: () => _addWindow(draft, OrderChannel.collection),
            ),
            ...draft.collectionWindows.map(_windowTile),
            _SettingsHeading(
              title: 'Delivery hours',
              actionLabel: 'Add window',
              onPressed: () => _addWindow(draft, OrderChannel.delivery),
            ),
            ...draft.deliveryWindows.map(_windowTile),
            _SettingsHeading(
              title: 'Delivery areas',
              actionLabel: 'Add area',
              onPressed: () => _addArea(draft),
            ),
            ...draft.serviceAreas.map(
              (area) => ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(area.name),
                subtitle: Text(
                  'Fee ${_money(area.deliveryFeeMinor)} · minimum ${_money(area.minimumOrderMinor)} · ${area.estimatedMinutes} min',
                ),
                trailing: IconButton(
                  tooltip: 'Remove area',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(
                    () => _draft = _copy(
                      draft,
                      serviceAreas: draft.serviceAreas
                          .where((item) => item.id != area.id)
                          .toList(),
                    ),
                  ),
                ),
              ),
            ),
            _SettingsHeading(
              title: 'Date overrides / closures',
              actionLabel: 'Add date',
              onPressed: () => _addDateOverride(draft),
            ),
            ...draft.dateOverrides.map(
              (override) => ListTile(
                leading: const Icon(Icons.event_busy_outlined),
                title: Text(
                  '${override.date.day.toString().padLeft(2, '0')}-${override.date.month.toString().padLeft(2, '0')}-${override.date.year}',
                ),
                subtitle: Text(
                  '${override.channel.label}: ${override.closed ? 'Closed' : 'Special hours'}${override.note.isEmpty ? '' : ' · ${override.note}'}',
                ),
                trailing: IconButton(
                  tooltip: 'Remove date override',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(
                    () => _draft = _copy(
                      draft,
                      dateOverrides: draft.dateOverrides
                          .where((item) => item.id != override.id)
                          .toList(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : () => _save(draft),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Save fulfilment settings'),
            ),
          ],
        );
      },
    );
  }

  Widget _windowTile(ServiceWindow window) => ListTile(
    dense: true,
    title: Text(_weekday(window.weekday)),
    subtitle: Text(
      '${_clock(window.opensMinute)}–${_clock(window.closesMinute)}',
    ),
    trailing: IconButton(
      tooltip: 'Remove window',
      icon: const Icon(Icons.delete_outline),
      onPressed: () {
        final draft = _draft;
        if (draft == null) return;
        final collection = [...draft.collectionWindows]..remove(window);
        final delivery = [...draft.deliveryWindows]..remove(window);
        setState(
          () => _draft = _copy(
            draft,
            collectionWindows: collection,
            deliveryWindows: delivery,
          ),
        );
      },
    ),
  );

  Future<void> _addWindow(
    VenueFulfilmentSettings draft,
    OrderChannel channel,
  ) async {
    var weekday = DateTime.monday;
    var opens = const TimeOfDay(hour: 12, minute: 0);
    var closes = const TimeOfDay(hour: 22, minute: 0);
    final result = await showAppDialog<ServiceWindow>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Add ${channel.label.toLowerCase()} window'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: weekday,
                decoration: const InputDecoration(labelText: 'Day'),
                items: [
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem(value: day, child: Text(_weekday(day))),
                ],
                onChanged: (value) =>
                    setState(() => weekday = value ?? weekday),
              ),
              ListTile(
                title: const Text('Opens'),
                trailing: Text(opens.format(context)),
                onTap: () async {
                  final value = await showTimePicker(
                    context: context,
                    initialTime: opens,
                  );
                  if (value != null) setState(() => opens = value);
                },
              ),
              ListTile(
                title: const Text('Closes'),
                trailing: Text(closes.format(context)),
                onTap: () async {
                  final value = await showTimePicker(
                    context: context,
                    initialTime: closes,
                  );
                  if (value != null) setState(() => closes = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final openMinute = opens.hour * 60 + opens.minute;
                final closeMinute = closes.hour * 60 + closes.minute;
                if (closeMinute <= openMinute) return;
                Navigator.pop(
                  dialogContext,
                  ServiceWindow(
                    weekday: weekday,
                    opensMinute: openMinute,
                    closesMinute: closeMinute,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(
      () => _draft = _copy(
        draft,
        collectionWindows: channel == OrderChannel.collection
            ? [...draft.collectionWindows, result]
            : null,
        deliveryWindows: channel == OrderChannel.delivery
            ? [...draft.deliveryWindows, result]
            : null,
      ),
    );
  }

  Future<void> _addArea(VenueFulfilmentSettings draft) async {
    final name = TextEditingController();
    final fee = TextEditingController(text: '0.00');
    final minimum = TextEditingController(text: '0.00');
    final minutes = TextEditingController(text: '45');
    final save = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add delivery area'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Town / area'),
              ),
              TextField(
                controller: fee,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Delivery fee'),
              ),
              TextField(
                controller: minimum,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Minimum order'),
              ),
              TextField(
                controller: minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Estimated minutes',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (save == true && name.text.trim().isNotEmpty && mounted) {
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      setState(
        () => _draft = _copy(
          draft,
          serviceAreas: [
            ...draft.serviceAreas,
            ServiceArea(
              id: id,
              name: name.text.trim(),
              deliveryFeeMinor: _minor(fee.text),
              minimumOrderMinor: _minor(minimum.text),
              estimatedMinutes: int.tryParse(minutes.text) ?? 45,
            ),
          ],
        ),
      );
    }
    name.dispose();
    fee.dispose();
    minimum.dispose();
    minutes.dispose();
  }

  Future<void> _addDateOverride(VenueFulfilmentSettings draft) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    var channel = OrderChannel.collection;
    final note = TextEditingController();
    final save = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Close a service date'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<OrderChannel>(
                initialValue: channel,
                items: const [
                  DropdownMenuItem(
                    value: OrderChannel.collection,
                    child: Text('Collection'),
                  ),
                  DropdownMenuItem(
                    value: OrderChannel.delivery,
                    child: Text('Delivery'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => channel = value ?? channel),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Reason / note (optional)',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add closure'),
            ),
          ],
        ),
      ),
    );
    if (save == true && mounted) {
      final key = '${date.toIso8601String().split('T').first}-${channel.name}';
      setState(
        () => _draft = _copy(
          draft,
          dateOverrides: [
            ...draft.dateOverrides.where((item) => item.id != key),
            ServiceDateOverride(
              id: key,
              date: date,
              channel: channel,
              note: note.text.trim(),
            ),
          ],
        ),
      );
    }
    note.dispose();
  }

  Future<void> _save(VenueFulfilmentSettings draft) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(fulfilmentRepositoryProvider)
          .saveSettings(scope: widget.scope, settings: draft);
      if (!mounted) return;
      setState(() => _draft = null);
      showAppNotification(
        context,
        ref: ref,
        title: 'Fulfilment settings saved',
        message: 'Channels, hours, areas and closures are now active.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save fulfilment settings', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Settings were not saved',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _weekday(int value) => const [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ][(value - 1).clamp(0, 6)];
  String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  String _money(int minor) => (minor / 100).toStringAsFixed(2);
  int _minor(String value) =>
      ((double.tryParse(value.trim()) ?? 0) * 100).round();
}

class _SettingsHeading extends StatelessWidget {
  const _SettingsHeading({
    required this.title,
    required this.actionLabel,
    required this.onPressed,
  });
  final String title;
  final String actionLabel;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: Text(actionLabel),
      ),
    ],
  );
}

class _CoursesTab extends ConsumerWidget {
  const _CoursesTab({required this.scope});
  final VenueScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final courses = ref.watch(venueCoursesProvider);
    return Scaffold(
      body: courses.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Load venue courses', error, stack);
          return Center(child: Text('Courses could not be loaded: $error'));
        },
        data: (items) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ListTile(
              leading: Icon(Icons.flash_on_outlined),
              title: Text('Standard'),
              subtitle: Text(
                'Immediate release · safe default for existing products',
              ),
            ),
            for (final item in items)
              ListTile(
                leading: CircleAvatar(child: Text('${item.sequence}')),
                title: Text(item.name),
                subtitle: Text(
                  '${item.releasePolicy.name} · amber ${item.amberMinutes}m · red ${item.redMinutes}m',
                ),
                trailing: IconButton(
                  tooltip: 'Edit course',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editCourse(context, ref, scope, item),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editCourse(
          context,
          ref,
          scope,
          const MenuCourse(id: 'new', name: '', sequence: 1),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add course'),
      ),
    );
  }
}

Future<void> _editCourse(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  MenuCourse course,
) async {
  final name = TextEditingController(text: course.name);
  final sequence = TextEditingController(text: '${course.sequence}');
  final amber = TextEditingController(text: '${course.amberMinutes}');
  final red = TextEditingController(text: '${course.redMinutes}');
  var policy = course.releasePolicy;
  final result = await showAppDialog<MenuCourse>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(course.id == 'new' ? 'Add course' : 'Edit course'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: sequence,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Display order'),
              ),
              DropdownButtonFormField<CourseReleasePolicy>(
                initialValue: policy,
                decoration: const InputDecoration(labelText: 'Release policy'),
                items: CourseReleasePolicy.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => policy = value ?? policy),
              ),
              TextField(
                controller: amber,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Amber warning (minutes)',
                ),
              ),
              TextField(
                controller: red,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Red warning (minutes)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              MenuCourse(
                id: course.id,
                name: name.text.trim(),
                sequence: int.tryParse(sequence.text) ?? 0,
                releasePolicy: policy,
                amberMinutes: int.tryParse(amber.text) ?? 15,
                redMinutes: int.tryParse(red.text) ?? 25,
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  sequence.dispose();
  amber.dispose();
  red.dispose();
  if (result == null || result.name.isEmpty) return;
  await ref.read(fulfilmentRepositoryProvider).saveCourse(scope, result);
}

class _CustomersTab extends ConsumerStatefulWidget {
  const _CustomersTab({required this.scope});
  final VenueScope scope;

  @override
  ConsumerState<_CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends ConsumerState<_CustomersTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(venueCustomersProvider);
    return Scaffold(
      body: customers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Load venue customers', error, stack);
          return Center(child: Text('Customers could not be loaded: $error'));
        },
        data: (items) {
          final terms = _query.toLowerCase().trim().split(RegExp(r'\s+'));
          final filtered = items.where((item) {
            final value =
                '${item.displayName} ${item.phoneNumbers.join(' ')} ${item.email ?? ''} ${item.addresses.map((address) => '${address.town} ${address.area} ${address.addressLines}').join(' ')}'
                    .toLowerCase();
            return terms.where((term) => term.isNotEmpty).every(value.contains);
          }).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search name, phone, email or address',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text('No matching telephone-order customers.'),
                  ),
                )
              else
                for (final item in filtered)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(item.displayName),
                    subtitle: Text(
                      '${item.phoneNumbers.join(' · ')} · ${item.claimStatus}${item.addresses.isEmpty ? '' : '\n${item.addresses.map((address) => '${address.label}: ${address.area}, ${address.town}').join(' · ')}'}',
                    ),
                    isThreeLine: item.addresses.isNotEmpty,
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit customer',
                      onPressed: () => showVenueCustomerEditor(
                        context: context,
                        ref: ref,
                        scope: widget.scope,
                        existing: item,
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showVenueCustomerEditor(
          context: context,
          ref: ref,
          scope: widget.scope,
        ),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Telephone customer'),
      ),
    );
  }
}
