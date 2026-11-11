part of '../pos_page.dart';

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      OrderStatus.open => ('Open', Colors.orange),
      OrderStatus.pendingApproval => ('Awaiting approval', Colors.purple),
      OrderStatus.sent => ('Sent', Colors.green),
      OrderStatus.closed => ('Closed', Colors.blueGrey),
      OrderStatus.rolledOver => ('Rolled over', Colors.blue),
    };
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 4),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

Future<bool> _ensureOrderLocation(BuildContext context, WidgetRef ref) async {
  // Demo mode has no venue-backed table or named-tab registry.
  if (ref.read(activeVenueScopeProvider) == null) return true;
  final order = ref.read(activeOrderProvider);
  if (order.channel != OrderChannel.dineIn ||
      order.tableId != null ||
      order.tabName?.trim().isNotEmpty == true) {
    return true;
  }
  return await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => const _OrderLocationPage(),
        ),
      ) ??
      false;
}

Future<void> _showFulfilmentOrderDialog(
  BuildContext context,
  OrderChannel channel, {
  VoidCallback? onStarted,
}) async {
  final started = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => _OrderLocationPage(initialChannel: channel),
    ),
  );
  if (started == true && context.mounted) onStarted?.call();
}

bool _serviceAreaMatchesAddress(
  ServiceArea serviceArea,
  CustomerAddress address,
) {
  String normalized(String value) => value.trim().toLowerCase();
  final addressTown = normalized(address.town);
  final addressDistrict = normalized(address.area);
  final areaTown = normalized(serviceArea.town);
  final areaDistrict = normalized(serviceArea.district);
  final areaName = normalized(serviceArea.name);
  // New records match the structured district + town pair. The name fallback
  // keeps existing venues working where older service areas stored only town.
  return (areaTown.isNotEmpty &&
          areaTown == addressTown &&
          (areaDistrict.isEmpty || areaDistrict == addressDistrict)) ||
      areaName == addressTown ||
      (areaName == addressDistrict && areaTown.isEmpty);
}

/// Stable route used by every new-order entry point.
///
/// This deliberately is not a dialog. The old implementation stacked the
/// location, customer and fulfilment dialogs while the POS order provider was
/// rebuilding beneath them. Flutter could then rebuild a removed semantics
/// node and crash in debug/release accessibility modes. A dedicated route
/// keeps one owner alive until the order location has been committed.
class _OrderLocationPage extends ConsumerStatefulWidget {
  const _OrderLocationPage({this.initialChannel});

  final OrderChannel? initialChannel;

  @override
  ConsumerState<_OrderLocationPage> createState() => _OrderLocationPageState();
}

class _OrderLocationPageState extends ConsumerState<_OrderLocationPage> {
  final _tabName = TextEditingController();
  bool _saving = false;
  String? _error;
  bool _initialChannelHandled = false;

  @override
  void dispose() {
    _tabName.dispose();
    super.dispose();
  }

  Future<void> _selectTable(DiningTable table) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(activeOrderProvider.notifier).openTable(table.id);
      ref.read(selectedTableProvider.notifier).select(table.id);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Choose table for new order', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openNamedTab() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(activeOrderProvider.notifier).openNamedTab(_tabName.text);
      ref.read(selectedTableProvider.notifier).select('');
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Open named tab for new order', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectNamedTab(OpenNamedTab tab) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      ref.read(activeOrderProvider.notifier).openExistingNamedTab(tab);
      ref.read(selectedTableProvider.notifier).select('');
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Choose existing named tab for order', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _startFulfilment(
    OrderChannel channel,
    VenueFulfilmentSettings settings,
  ) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final scope = ref.read(activeVenueScopeProvider);
      if (scope == null) throw StateError('Select a venue first.');
      final cached = ref.read(venueCustomersProvider).value;
      late final List<VenueCustomer> loadedCustomers;
      if (cached != null) {
        loadedCustomers = cached;
      } else if (!kIsWeb &&
          VenueHubClientRegistry.instance.hasUsableSession(scope)) {
        // Hub snapshots are replayable state. Reading them directly avoids
        // waiting for a broadcast stream to emit a change that may never be
        // needed while the cached customer list is already complete.
        loadedCustomers = VenueHubOfflineView.instance.customers;
      } else {
        loadedCustomers = await ref
            .read(fulfilmentRepositoryProvider)
            .watchCustomers(scope)
            .first
            .timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      final customers = loadedCustomers
          .where(
            (customer) =>
                customer.phoneNumbers.any((number) => number.trim().isNotEmpty),
          )
          .toList(growable: false);
      await _chooseFulfilmentCustomer(channel, customers, settings);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Start ${channel.label} order', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _error = 'Could not load customers. Check the connection and retry.';
      });
      showAppNotification(
        context,
        ref: ref,
        title: '${channel.label} order could not start',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseFulfilmentCustomer(
    OrderChannel channel,
    List<VenueCustomer> customers,
    VenueFulfilmentSettings settings,
  ) async {
    final selected = await _pickFulfilmentCustomer(channel, customers);
    if (selected == null || !mounted) return;
    DateTime? scheduledFor;
    FulfilmentStaffMember? selectedDriver;
    final drivers = channel == OrderChannel.delivery
        ? (ref.read(fulfilmentStaffProvider).value ??
                  const <FulfilmentStaffMember>[])
              .where((staff) => staff.roles.contains('driver'))
              .toList(growable: false)
        : const <FulfilmentStaffMember>[];
    CustomerAddress? selectedAddress = selected.addresses
        .where((item) => item.isDefault)
        .firstOrNull;
    selectedAddress ??= selected.addresses.firstOrNull;
    final activeAreas = settings.serviceAreas
        .where((area) => area.active)
        .toList(growable: false);
    ServiceArea? selectedArea;
    if (channel == OrderChannel.delivery && selectedAddress != null) {
      selectedArea = activeAreas
          .where((area) => _serviceAreaMatchesAddress(area, selectedAddress!))
          .firstOrNull;
    }
    selectedArea ??= activeAreas.length == 1 ? activeAreas.first : null;
    final address = TextEditingController(text: selectedAddress?.oneLine ?? '');
    String? validationError;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (customerContext) => StatefulBuilder(
        builder: (context, setCustomerState) => AlertDialog(
          scrollable: true,
          title: Text('Start ${channel.label.toLowerCase()} order'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(selected.displayName),
                subtitle: Text(selected.phoneNumbers.join(' · ')),
              ),
              if (channel == OrderChannel.delivery) ...[
                const SizedBox(height: 12),
                if (selected.addresses.isNotEmpty)
                  DropdownButtonFormField<CustomerAddress>(
                    initialValue: selectedAddress,
                    decoration: const InputDecoration(
                      labelText: 'Saved delivery address',
                      prefixIcon: Icon(Icons.location_on_outlined),
                    ),
                    items: [
                      for (final item in selected.addresses)
                        DropdownMenuItem(
                          value: item,
                          child: Text(
                            '${item.label}${item.isDefault ? ' · Default' : ''}',
                          ),
                        ),
                    ],
                    onChanged: (value) => setCustomerState(() {
                      selectedAddress = value;
                      address.text = value?.oneLine ?? '';
                      selectedArea = activeAreas
                          .where(
                            (area) =>
                                value != null &&
                                _serviceAreaMatchesAddress(area, value),
                          )
                          .firstOrNull;
                    }),
                  ),
                if (selected.addresses.isNotEmpty) const SizedBox(height: 8),
                TextField(
                  controller: address,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Delivery address / manual override',
                  ),
                  onChanged: (_) => setCustomerState(() {
                    if (selectedAddress?.oneLine != address.text.trim()) {
                      selectedAddress = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ServiceArea>(
                  initialValue: selectedArea,
                  decoration: const InputDecoration(
                    labelText: 'Delivery town / area',
                    prefixIcon: Icon(Icons.map_outlined),
                  ),
                  items: [
                    for (final area in activeAreas)
                      DropdownMenuItem(
                        value: area,
                        child: Text(
                          '${area.name} · ${(area.deliveryFeeMinor / 100).toStringAsFixed(2)}',
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setCustomerState(() => selectedArea = value),
                ),
                if (selectedAddress?.notes.trim().isNotEmpty == true)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.directions_outlined),
                    title: const Text('Driver directions'),
                    subtitle: Text(selectedAddress!.notes),
                  ),
                if (selectedAddress?.latitude != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.pin_drop_outlined),
                    title: const Text('Map pin'),
                    subtitle: Text(
                      '${selectedAddress!.latitude}, ${selectedAddress!.longitude}',
                    ),
                  ),
                if (drivers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<FulfilmentStaffMember>(
                    initialValue: selectedDriver,
                    decoration: const InputDecoration(
                      labelText: 'Delivery driver (optional)',
                      prefixIcon: Icon(Icons.delivery_dining_outlined),
                    ),
                    items: [
                      for (final driver in drivers)
                        DropdownMenuItem(
                          value: driver,
                          child: Text(driver.name),
                        ),
                    ],
                    onChanged: (value) =>
                        setCustomerState(() => selectedDriver = value),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_outlined),
                title: Text(
                  scheduledFor == null
                      ? 'ASAP'
                      : '${scheduledFor!.day.toString().padLeft(2, '0')}-${scheduledFor!.month.toString().padLeft(2, '0')}-${scheduledFor!.year} ${scheduledFor!.hour.toString().padLeft(2, '0')}:${scheduledFor!.minute.toString().padLeft(2, '0')}',
                ),
                subtitle: const Text('Collection / delivery time'),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: scheduledFor ?? DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (date == null || !context.mounted) return;
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(
                      scheduledFor ??
                          DateTime.now().add(const Duration(minutes: 30)),
                    ),
                  );
                  if (time == null) return;
                  setCustomerState(
                    () => scheduledFor = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      time.hour,
                      time.minute,
                    ),
                  );
                },
              ),
              if (validationError != null)
                Text(
                  validationError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(customerContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (channel == OrderChannel.delivery &&
                    address.text.trim().isEmpty) {
                  setCustomerState(
                    () => validationError = 'Enter the delivery address.',
                  );
                  return;
                }
                if (channel == OrderChannel.delivery && selectedArea == null) {
                  setCustomerState(
                    () => validationError = activeAreas.isEmpty
                        ? 'A manager must configure at least one delivery area.'
                        : 'Choose the delivery town / area.',
                  );
                  return;
                }
                Navigator.pop(customerContext, true);
              },
              child: const Text('Start order'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      // Do not dismiss two stacked dialogs while the order controller is
      // still rebuilding the POS tree. Besides losing server errors, that
      // route race can make Flutter flush semantics while parent data is
      // dirty (the assertion previously seen on Collection/Delivery).
      ref
          .read(activeOrderProvider.notifier)
          .startFulfilmentOrder(
            channel: channel,
            customerId: selected.id,
            customerName: selected.displayName,
            customerPhone: selected.phoneNumbers.first,
            deliveryAddress: channel == OrderChannel.delivery
                ? address.text
                : null,
            deliveryAddressLabel: channel == OrderChannel.delivery
                ? selectedAddress?.label
                : null,
            deliveryLatitude: channel == OrderChannel.delivery
                ? selectedAddress?.latitude
                : null,
            deliveryLongitude: channel == OrderChannel.delivery
                ? selectedAddress?.longitude
                : null,
            serviceAreaId: channel == OrderChannel.delivery
                ? selectedArea?.id
                : null,
            serviceAreaName: channel == OrderChannel.delivery
                ? selectedArea?.name
                : null,
            deliveryFeeMinor: channel == OrderChannel.delivery
                ? selectedArea?.deliveryFeeMinor ?? 0
                : 0,
            scheduledFor: scheduledFor,
            assignedDriverId: selectedDriver?.id,
            assignedDriverName: selectedDriver?.name,
          );
      // Collection and delivery orders have no table tile to select again.
      // Move straight to the menu so staff can begin adding the order.
      ref.read(posCompactTabProvider.notifier).select(1);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(true);
    }
    address.dispose();
  }

  Future<VenueCustomer?> _pickFulfilmentCustomer(
    OrderChannel channel,
    List<VenueCustomer> customers,
  ) async {
    final search = TextEditingController();
    try {
      final selected = await showAppDialog<Object>(
        context: context,
        builder: (pickerContext) {
          var query = '';
          return StatefulBuilder(
            builder: (context, setPickerState) {
              final media = MediaQuery.of(context);
              // Use the actual unobscured viewport. AlertDialog's separately
              // measured title/content/actions can still overflow on a short
              // landscape tablet once the software keyboard is visible.
              final unobscuredHeight =
                  media.size.height - media.viewInsets.bottom;
              final pickerHeight = (unobscuredHeight - 24).clamp(120.0, 620.0);
              final terms = query
                  .trim()
                  .toLowerCase()
                  .split(RegExp(r'\s+'))
                  .where((term) => term.isNotEmpty)
                  .toList(growable: false);
              final filtered = customers
                  .where((customer) {
                    final searchable =
                        '${customer.displayName} ${customer.phoneNumbers.join(' ')} ${customer.email ?? ''} ${customer.addresses.map((address) => '${address.town} ${address.area} ${address.addressLines}').join(' ')}'
                            .toLowerCase();
                    return terms.every(searchable.contains);
                  })
                  .toList(growable: false);
              return Dialog(
                insetPadding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 560,
                  height: pickerHeight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Choose ${channel.label.toLowerCase()} customer',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: search,
                          autofocus: customers.isNotEmpty,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Name, phone, email or address',
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      search.clear();
                                      setPickerState(() => query = '');
                                    },
                                    icon: const Icon(Icons.clear),
                                  ),
                          ),
                          onChanged: (value) =>
                              setPickerState(() => query = value),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: filtered.isEmpty
                              ? Center(
                                  child: Text(
                                    customers.isEmpty
                                        ? 'No customers yet. Add the first customer below.'
                                        : 'No customers match this search.',
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : ListView.builder(
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: filtered.length,
                                  itemBuilder: (context, index) {
                                    final customer = filtered[index];
                                    final address =
                                        customer.addresses.firstOrNull;
                                    return ListTile(
                                      dense: true,
                                      leading: const Icon(Icons.person_outline),
                                      title: Text(customer.displayName),
                                      subtitle: Text(
                                        '${customer.phoneNumbers.join(' · ')}${address == null ? '' : '\n${address.area}, ${address.town}'}',
                                      ),
                                      isThreeLine: address != null,
                                      trailing: IconButton(
                                        tooltip: 'Edit customer or add address',
                                        onPressed: () => Navigator.pop(
                                          pickerContext,
                                          _EditFulfilmentCustomer(customer),
                                        ),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      onTap: () => Navigator.pop(
                                        pickerContext,
                                        customer,
                                      ),
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(pickerContext),
                              child: const Text('Cancel'),
                            ),
                            FilledButton.icon(
                              // Close this picker completely before opening
                              // the editor; stacked routes caused semantics
                              // races when a customer stream refreshed.
                              onPressed: () => Navigator.pop(
                                pickerContext,
                                const _CreateFulfilmentCustomer(),
                              ),
                              icon: const Icon(Icons.person_add_alt_1),
                              label: const Text('New customer'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
      if (selected is VenueCustomer) return selected;
      if (selected is _EditFulfilmentCustomer && mounted) {
        final scope = ref.read(activeVenueScopeProvider);
        if (scope == null) return null;
        return await showVenueCustomerEditor(
          context: context,
          ref: ref,
          scope: scope,
          existing: selected.customer,
          requireAddress: channel == OrderChannel.delivery,
        );
      }
      if (selected is _CreateFulfilmentCustomer && mounted) {
        final scope = ref.read(activeVenueScopeProvider);
        if (scope == null) return null;
        return await showVenueCustomerEditor(
          context: context,
          ref: ref,
          scope: scope,
          requireAddress: channel == OrderChannel.delivery,
        );
      }
      return null;
    } finally {
      search.dispose();
    }
  }

  void _requestFulfilment(
    OrderChannel channel,
    AsyncValue<VenueFulfilmentSettings> settings,
  ) {
    settings.when(
      data: (value) {
        final enabled = channel == OrderChannel.delivery
            ? value.deliveryEnabled
            : value.collectionEnabled;
        if (!enabled) {
          setState(
            () => _error =
                '${channel.label} is disabled for this venue. Enable it in Settings → Collection, delivery & courses and save the settings.',
          );
          return;
        }
        unawaited(_startFulfilment(channel, value));
      },
      loading: () => setState(
        () => _error = 'Venue collection and delivery settings are loading.',
      ),
      error: (error, stackTrace) {
        AppLogger.error('Load fulfilment settings for POS', error, stackTrace);
        setState(
          () => _error =
              'Collection and delivery settings could not be loaded. Check the connection and retry.',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tablesState = ref.watch(diningTablesProvider);
    final tabsState = ref.watch(openNamedTabsProvider);
    final tables = tablesState.when(
      data: (items) => items,
      loading: () => const <DiningTable>[],
      error: (error, stackTrace) {
        AppLogger.error('Load tables for new order', error, stackTrace);
        return const <DiningTable>[];
      },
    );
    final namedTabs = tabsState.when(
      data: (items) => items,
      loading: () => const <OpenNamedTab>[],
      error: (error, stackTrace) {
        AppLogger.error('Load named tabs for new order', error, stackTrace);
        return const <OpenNamedTab>[];
      },
    );
    final locationsLoading = tablesState.isLoading || tabsState.isLoading;
    final fulfilmentSettings = ref.watch(venueFulfilmentSettingsProvider);
    if (widget.initialChannel != null &&
        !_initialChannelHandled &&
        !fulfilmentSettings.isLoading) {
      _initialChannelHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _requestFulfilment(widget.initialChannel!, fulfilmentSettings);
        }
      });
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.close_rounded),
        ),
        title: const Text('Start this order'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Icon(Icons.receipt_long_outlined, size: 36),
                const SizedBox(height: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Choose the table, or open a named customer tab first.',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : () => _requestFulfilment(
                                  OrderChannel.collection,
                                  fulfilmentSettings,
                                ),
                          icon: const Icon(Icons.shopping_bag_outlined),
                          label: const Text('Collection'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : () => _requestFulfilment(
                                  OrderChannel.delivery,
                                  fulfilmentSettings,
                                ),
                          icon: const Icon(Icons.delivery_dining_outlined),
                          label: const Text('Delivery'),
                        ),
                      ],
                    ),
                    if (_saving) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 12),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    // Keep one scroll owner for the complete location page.
                    // A nested, height-capped ListView trapped touch drags on
                    // small tablets, making open named tabs and the controls
                    // below the table list difficult to reach.
                    locationsLoading
                        ? const SizedBox(
                            height: 120,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (tables.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    4,
                                  ),
                                  child: Text(
                                    'Tables',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                              for (final table in tables)
                                ListTile(
                                  enabled: !_saving,
                                  leading: const Icon(
                                    Icons.table_restaurant_rounded,
                                  ),
                                  title: Text(table.label),
                                  subtitle: Text('${table.seats} seats'),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                  ),
                                  onTap: () => _selectTable(table),
                                ),
                              if (tables.isNotEmpty && namedTabs.isNotEmpty)
                                const Divider(height: 16),
                              if (namedTabs.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    4,
                                  ),
                                  child: Text(
                                    'Open named tabs',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                              if (namedTabs.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final tab in namedTabs)
                                        SizedBox(
                                          width: 132,
                                          child: OutlinedButton.icon(
                                            onPressed: _saving
                                                ? null
                                                : () => _selectNamedTab(tab),
                                            icon: const Icon(
                                              Icons.person_outline_rounded,
                                              size: 18,
                                            ),
                                            label: Text(
                                              tab.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (tables.isEmpty && namedTabs.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                    'No tables or open named tabs are available.',
                                  ),
                                ),
                            ],
                          ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _tabName,
                      enabled: !_saving,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Or open a named tab',
                        hintText: 'For example, John N',
                      ),
                      onSubmitted: (_) {
                        if (!_saving) _openNamedTab();
                      },
                    ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _openNamedTab,
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Open named tab'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateFulfilmentCustomer {
  const _CreateFulfilmentCustomer();
}

class _EditFulfilmentCustomer {
  const _EditFulfilmentCustomer(this.customer);

  final VenueCustomer customer;
}

Future<void> _showNamedTabDialog(BuildContext context, WidgetRef ref) async {
  final nameController = TextEditingController();
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.person_outline_rounded),
      title: const Text('Open named tab'),
      content: TextField(
        controller: nameController,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Customer or tab name',
          hintText: 'For example, John N',
          helperText:
              'Entering an existing open name returns to that tab instead.',
        ),
        onSubmitted: (_) {},
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () async {
            try {
              await ref
                  .read(activeOrderProvider.notifier)
                  .openNamedTab(nameController.text);
              ref.read(selectedTableProvider.notifier).select('');
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (!context.mounted) return;
              showAppNotification(
                context,
                ref: ref,
                title: 'Named tab ready',
                message: 'Named tab is ready.',
                level: AppNotificationLevel.success,
              );
            } on Object catch (error, stackTrace) {
              AppLogger.error('Open named tab', error, stackTrace);
              if (!dialogContext.mounted) return;
              showAppNotification(
                dialogContext,
                ref: ref,
                title: 'Could not open named tab',
                message: '$error',
                level: AppNotificationLevel.error,
              );
            }
          },
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open tab'),
        ),
      ],
    ),
  ).whenComplete(nameController.dispose);
}

Future<void> _showSplitBillSheet(
  BuildContext pageContext, {
  required WidgetRef ref,
  required PosOrder order,
  required String currencyCode,
}) async {
  final selectedQuantities = <String, int>{
    for (final line in order.lines) line.id: 0,
  };
  var saving = false;
  await showAppModalBottomSheet<void>(
    context: pageContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        final selectedQuantity = selectedQuantities.values.fold<int>(
          0,
          (total, quantity) => total + quantity,
        );
        final totalQuantity = order.lines.fold<int>(
          0,
          (total, line) => total + line.quantity,
        );
        final splitTotal = order.lines.fold<int>(0, (total, line) {
          return total +
              (selectedQuantities[line.id] ?? 0) * line.unitPriceMinor;
        });
        final canSplit =
            !saving && selectedQuantity > 0 && selectedQuantity < totalQuantity;

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Create a separate bill',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Move the items one guest will pay for. The food has already been sent, so this does not print another kitchen or bar ticket.',
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : () => setSheetState(() {
                                var remainingToSelect = totalQuantity ~/ 2;
                                for (final line in order.lines) {
                                  final selected = remainingToSelect
                                      .clamp(0, line.quantity)
                                      .toInt();
                                  selectedQuantities[line.id] = selected;
                                  remainingToSelect -= selected;
                                }
                              }),
                        icon: const Icon(Icons.balance_rounded),
                        label: const Text('Select half of items'),
                      ),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => setSheetState(() {
                                for (final line in order.lines) {
                                  selectedQuantities[line.id] = 0;
                                }
                              }),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  Expanded(
                    child: ListView.separated(
                      itemCount: order.lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = order.lines[index];
                        final selected = selectedQuantities[line.id] ?? 0;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(line.productName),
                          subtitle: Text(
                            '${line.quantity} available · ${formatMoney(line.unitPriceMinor, currencyCode: currencyCode)} each',
                          ),
                          trailing: SizedBox(
                            width: 140,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  tooltip: 'Remove from split',
                                  onPressed: saving || selected == 0
                                      ? null
                                      : () => setSheetState(
                                          () => selectedQuantities[line.id] =
                                              selected - 1,
                                        ),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                SizedBox(
                                  width: 24,
                                  child: Text(
                                    '$selected',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Add to split',
                                  onPressed: saving || selected >= line.quantity
                                      ? null
                                      : () => setSheetState(
                                          () => selectedQuantities[line.id] =
                                              selected + 1,
                                        ),
                                  icon: const Icon(Icons.add_circle_outline),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Text('Separate bill total'),
                      const Spacer(),
                      Text(
                        formatMoney(splitTotal, currencyCode: currencyCode),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !canSplit
                          ? null
                          : () async {
                              setSheetState(() => saving = true);
                              try {
                                final result = await ref
                                    .read(activeOrderProvider.notifier)
                                    .splitBillByItems(selectedQuantities);
                                if (!sheetContext.mounted) return;
                                Navigator.pop(sheetContext);
                                if (!pageContext.mounted) return;
                                showAppNotification(
                                  pageContext,
                                  ref: ref,
                                  title: 'Separate bill ready',
                                  message:
                                      '${formatMoney(result.splitTotalMinor, currencyCode: currencyCode)} is ready for payment. The remaining items stay on the main table bill.',
                                  level: AppNotificationLevel.success,
                                );
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Create separate bill',
                                  error,
                                  stackTrace,
                                );
                                if (!sheetContext.mounted) return;
                                setSheetState(() => saving = false);
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Could not split this bill',
                                  message: '$error',
                                  level: AppNotificationLevel.error,
                                );
                              }
                            },
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.call_split_rounded),
                      label: Text(
                        saving
                            ? 'Creating separate bill…'
                            : 'Create separate bill',
                      ),
                    ),
                  ),
                  if (selectedQuantity == totalQuantity) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Use Pay to settle every item on this table; a split must leave items on the main bill.',
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
