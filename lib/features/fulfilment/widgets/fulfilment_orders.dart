part of '../fulfilment_management_page.dart';

class _FulfilmentOrdersTab extends ConsumerStatefulWidget {
  const _FulfilmentOrdersTab({required this.scope, this.assignedDriverId});
  final VenueScope scope;
  final String? assignedDriverId;

  @override
  ConsumerState<_FulfilmentOrdersTab> createState() =>
      _FulfilmentOrdersTabState();
}

class _FulfilmentOrdersTabState extends ConsumerState<_FulfilmentOrdersTab> {
  late DateTimeRange _dateRange;
  FulfilmentStatus? _statusFilter;
  String _searchQuery = '';
  bool _showFilters = false;
  final TextEditingController _searchController = TextEditingController();
  VenueScope get scope => widget.scope;

  @override
  void initState() {
    super.initState();
    final today = DateUtils.dateOnly(DateTime.now());
    _dateRange = DateTimeRange(start: today, end: today);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = DateUtils.dateOnly(_dateRange.start);
    final endExclusive = DateUtils.dateOnly(
      _dateRange.end,
    ).add(const Duration(days: 1));
    final orders = ref.watch(
      fulfilmentOrderHistoryProvider(
        FulfilmentHistoryQuery(
          scope: scope,
          startMillis: start.millisecondsSinceEpoch,
          endExclusiveMillis: endExclusive.millisecondsSinceEpoch,
          assignedDriverId: widget.assignedDriverId,
        ),
      ),
    );
    final session = ref.watch(activeStaffPinSessionProvider);
    final canManageOrders =
        session?.roles.any((role) => role == 'owner' || role == 'manager') ??
        false;
    final staff = canManageOrders
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
        final items =
            allItems
                .where((order) {
                  if (widget.assignedDriverId != null &&
                      order.assignedDriverId != widget.assignedDriverId) {
                    return false;
                  }
                  final value = order.scheduledFor ?? order.openedAt;
                  final date = DateUtils.dateOnly(value.toLocal());
                  if (date.isBefore(_dateRange.start) ||
                      date.isAfter(_dateRange.end)) {
                    return false;
                  }
                  if (_statusFilter != null &&
                      order.fulfilmentStatus != _statusFilter) {
                    return false;
                  }
                  final query = _searchQuery.trim().toLowerCase();
                  if (query.isEmpty) return true;
                  return <String?>[
                    order.customerName,
                    order.customerPhone,
                    order.deliveryAddress,
                    order.deliveryAddressLabel,
                    order.serviceAreaName,
                    order.assignedDriverName,
                    order.id,
                    order.channel.label,
                    _statusLabel(order.fulfilmentStatus),
                  ].whereType<String>().any(
                    (value) => value.toLowerCase().contains(query),
                  );
                })
                .toList(growable: false)
              ..sort((left, right) {
                final leftTime = left.scheduledFor ?? left.openedAt;
                final rightTime = right.scheduledFor ?? right.openedAt;
                return leftTime.compareTo(rightTime);
              });
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_rangeLabel(_dateRange)} · ${items.length} order${items.length == 1 ? '' : 's'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            setState(() => _showFilters = !_showFilters),
                        icon: Icon(
                          _showFilters
                              ? Icons.filter_alt_off_outlined
                              : Icons.filter_alt_outlined,
                        ),
                        label: Text(
                          _showFilters ? 'Hide filters' : 'Show filters',
                        ),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.topCenter,
                    child: !_showFilters
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Card.filled(
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    TextField(
                                      controller: _searchController,
                                      onChanged: (value) =>
                                          setState(() => _searchQuery = value),
                                      decoration: const InputDecoration(
                                        labelText: 'Search orders',
                                        hintText:
                                            'Customer, phone, address, driver…',
                                        prefixIcon: Icon(Icons.search_rounded),
                                        isDense: true,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        final compact =
                                            constraints.maxWidth < 620;
                                        final status =
                                            DropdownButtonFormField<
                                              FulfilmentStatus?
                                            >(
                                              initialValue: _statusFilter,
                                              isExpanded: true,
                                              decoration: const InputDecoration(
                                                labelText: 'Status',
                                                isDense: true,
                                              ),
                                              items: [
                                                const DropdownMenuItem(
                                                  value: null,
                                                  child: Text('All statuses'),
                                                ),
                                                for (final value
                                                    in FulfilmentStatus.values)
                                                  DropdownMenuItem(
                                                    value: value,
                                                    child: Text(
                                                      _statusLabel(value),
                                                    ),
                                                  ),
                                              ],
                                              onChanged: (value) => setState(
                                                () => _statusFilter = value,
                                              ),
                                            );
                                        final dates = OutlinedButton.icon(
                                          onPressed: _chooseDateRange,
                                          icon: const Icon(
                                            Icons.date_range_outlined,
                                          ),
                                          label: Text(
                                            _rangeLabel(_dateRange),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        );
                                        final clear = TextButton.icon(
                                          onPressed: _resetFilters,
                                          icon: const Icon(
                                            Icons.restart_alt_rounded,
                                          ),
                                          label: const Text('Reset'),
                                        );
                                        if (compact) {
                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              status,
                                              const SizedBox(height: 10),
                                              dates,
                                              clear,
                                            ],
                                          );
                                        }
                                        return Row(
                                          children: [
                                            Expanded(child: status),
                                            const SizedBox(width: 10),
                                            Expanded(child: dates),
                                            clear,
                                          ],
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        'No collection or delivery orders match these filters.',
                      ),
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
                            order.fulfilmentStatus ==
                            FulfilmentStatus.driverDeclined;
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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
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
                                if (order.assignedDriverName?.isNotEmpty ==
                                    true)
                                  Text('Driver: ${order.assignedDriverName}'),
                                if (driverDeclined)
                                  const Text(
                                    'Driver declined — choose another driver.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (order.channel ==
                                            OrderChannel.delivery &&
                                        canManageOrders)
                                      OutlinedButton.icon(
                                        onPressed:
                                            !canManageOrders || drivers.isEmpty
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
                                    if (order.channel ==
                                            OrderChannel.delivery ||
                                        order.fulfilmentStatus ==
                                            FulfilmentStatus
                                                .readyForCollection ||
                                        order.fulfilmentStatus ==
                                            FulfilmentStatus.outForDelivery)
                                      OutlinedButton.icon(
                                        onPressed: () => _printDeliveryNote(
                                          context,
                                          ref,
                                          order,
                                        ),
                                        icon: const Icon(Icons.print_outlined),
                                        label: Text(
                                          order.channel == OrderChannel.delivery
                                              ? 'Driver ticket'
                                              : 'Collection note',
                                        ),
                                      ),
                                    if (widget.assignedDriverId != null &&
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
                                        onPressed: () => _updateStatus(
                                          context,
                                          ref,
                                          order,
                                          next,
                                        ),
                                        child: Text(_statusLabel(next)),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  String _dateLabel(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}-${value.month.toString().padLeft(2, '0')}-${value.year}';

  String _rangeLabel(DateTimeRange range) =>
      DateUtils.isSameDay(range.start, range.end)
      ? _dateLabel(range.start)
      : '${_dateLabel(range.start)} – ${_dateLabel(range.end)}';

  Future<void> _chooseDateRange() async {
    final selected = await showDateRangePicker(
      context: context,
      initialDateRange: _dateRange,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 7)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selected != null && mounted) {
      setState(
        () => _dateRange = DateTimeRange(
          start: DateUtils.dateOnly(selected.start),
          end: DateUtils.dateOnly(selected.end),
        ),
      );
    }
  }

  void _resetFilters() {
    final today = DateUtils.dateOnly(DateTime.now());
    setState(() {
      _dateRange = DateTimeRange(start: today, end: today);
      _statusFilter = null;
      _searchQuery = '';
      _searchController.clear();
    });
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
