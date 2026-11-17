import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/printer_device_repository.dart';
import '../../data/printer_route_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';
import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';
import 'local_printer_device_identity.dart';
import 'queued_native_print_worker.dart';
import 'receipt_paper_width.dart';
import 'venue_printer_routing_page.dart';

class BluetoothPrinterSetupPage extends ConsumerStatefulWidget {
  const BluetoothPrinterSetupPage({
    super.key,
    required this.restaurantName,
    required this.venueRoutingKey,
    required this.scope,
  });

  final String restaurantName;
  final String venueRoutingKey;
  final VenueScope? scope;

  @override
  ConsumerState<BluetoothPrinterSetupPage> createState() =>
      _BluetoothPrinterSetupPageState();
}

class _BluetoothPrinterSetupPageState
    extends ConsumerState<BluetoothPrinterSetupPage> {
  final BluetoothReceiptPrinter _printer = createBluetoothReceiptPrinter();
  final LocalPrinterDeviceIdentity _identity = LocalPrinterDeviceIdentity();
  final PrinterDeviceRepository _printerDevices = PrinterDeviceRepository(
    FirebaseFirestore.instance,
  );
  final PrinterRouteRepository _printerRoutes = PrinterRouteRepository(
    FirebaseFirestore.instance,
  );

  List<BluetoothReceiptPrinterDevice> _devices = const [];
  BluetoothReceiptPrinterDevice? _selected;
  BluetoothProductionRouting _routing = const BluetoothProductionRouting();
  bool _loading = true;
  bool _printing = false;
  bool _savingRouting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!_printer.isSupported) {
      setState(() {
        _loading = false;
        _error =
            'Bluetooth receipt printing is available only in the native Android app.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = await _printer.selectedDevice();
      final routing = await _printer.productionRouting(
        venueRoutingKey: widget.venueRoutingKey,
      );
      final devices = await _printer.pairedDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        final matching = devices.where(
          (device) => device.address == selected?.address,
        );
        _selected = matching.isEmpty
            ? selected
            : matching.first.copyWith(paperWidth: selected?.paperWidth);
        _routing = routing;
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load paired Bluetooth printers', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(BluetoothReceiptPrinterDevice device) async {
    try {
      await _printer.selectDevice(device);
      if (!mounted) return;
      setState(() => _selected = device);
      showAppNotification(
        context,
        title: 'Printer selected',
        message: '${device.name} is selected for test printing.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Select Bluetooth printer', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Could not select printer',
        message: _friendlyError(error),
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _clearSelection() async {
    try {
      await _printer.clearSelectedDevice();
      if (mounted) setState(() => _selected = null);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Clear Bluetooth printer selection', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Could not clear printer',
        message: _friendlyError(error),
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _selectPaperWidth(ReceiptPaperWidth paperWidth) async {
    final selected = _selected;
    if (selected == null) return;
    await _select(selected.copyWith(paperWidth: paperWidth));
  }

  Future<void> _testPrint() async {
    final selected = _selected;
    if (selected == null || _printing) return;
    setState(() => _printing = true);
    try {
      await _printer.printTestTicket(
        device: selected,
        restaurantName: widget.restaurantName,
      );
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Test print sent',
        message:
            'Test bytes were sent. Confirm that the complete ticket printed before enabling live routes.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Bluetooth test print', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Test print failed',
        message: _friendlyError(error),
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _saveRouting(BluetoothProductionRouting routing) async {
    if (_savingRouting) return;
    setState(() => _savingRouting = true);
    try {
      await _configureSecuredLiveQueue(routing);
      await _printer.saveProductionRouting(
        venueRoutingKey: widget.venueRoutingKey,
        routing: routing,
      );
      if (!mounted) return;
      setState(() => _routing = routing);
      showAppNotification(
        context,
        title: 'Printer routing saved',
        message: routing.enabled && routing.productionAreas.isNotEmpty
            ? 'This printer is enrolled and its selected live routes are ready.'
            : 'Live production routing is off for this venue.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save Bluetooth production routing', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Could not save printer routing',
        message: _friendlyError(error),
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _savingRouting = false);
    }
  }

  /// Makes the live path match the controls on this page. Test printing talks
  /// directly to Bluetooth, while live tickets are durably queued and require
  /// a venue-scoped device credential plus server routes. Previously the
  /// switch saved only the local preference, leaving managers to discover a
  /// second setup page after live jobs failed. Enabling an area now performs
  /// the complete authorised configuration in one transaction-like workflow.
  Future<void> _configureSecuredLiveQueue(
    BluetoothProductionRouting routing,
  ) async {
    final scope = widget.scope;
    final selected = _selected;
    if (scope == null) {
      throw StateError('Choose a venue before configuring live printing.');
    }
    if (selected == null) {
      throw StateError('Select the Bluetooth printer first.');
    }
    if (FirebaseAuth.instance.currentUser == null) {
      throw StateError('Sign in before configuring live printing.');
    }
    final hasSession = ref
        .read(activeStaffPinSessionProvider.notifier)
        .restoreCredentials();
    if (!hasSession) {
      throw StateError('Enter your staff PIN again before saving printers.');
    }

    final deviceId = await _identity.deviceIdForScope(scope);
    final credential = await _printerDevices.register(
      PrinterDevice(
        id: deviceId,
        venueId: scope.venueId,
        name: selected.name,
        platform: 'android',
        // An ESC/POS printer can handle any ticket type. Route selection below
        // determines which ones this particular installation actually gets.
        productionAreas: productionRouteAreas,
        transports: const ['bluetooth'],
        active: true,
      ),
      tenantId: scope.tenantId,
      // Selecting and enabling this physical printer is an explicit reconnect
      // action. Transfer routes from a stale registration with the same name
      // rather than leaving an unreachable device active.
      replaceExistingNamedDevice: true,
    );
    await _identity.saveCredential(scope, credential);

    final existingRoutes = await _printerRoutes.watchVenueRoutes(scope).first;
    final byArea = {
      for (final route in existingRoutes) route.productionArea: route,
    };
    for (final area in productionRouteAreas) {
      final selectedHere =
          routing.enabled && routing.productionAreas.contains(area);
      final existing = byArea[area];
      if (selectedHere) {
        await _printerRoutes.saveRoute(
          scope: scope,
          productionArea: area,
          primaryDeviceId: deviceId,
          fallbackDeviceId: existing?.fallbackDeviceId == deviceId
              ? null
              : existing?.fallbackDeviceId,
        );
      } else if (existing?.primaryDeviceId == deviceId) {
        // Removing this device from an area must not erase a separately
        // configured fallback. Promote it to primary when available.
        await _printerRoutes.saveRoute(
          scope: scope,
          productionArea: area,
          primaryDeviceId: existing?.fallbackDeviceId,
        );
      }
    }
    final liveSessionReady = await QueuedNativePrintWorker.instance
        .maintainHeartbeat(scope);
    if (!liveSessionReady) {
      throw StateError(
        'The venue server did not accept this printer for live queue access. '
        'The test connection is unchanged; check the staff permission and retry registration.',
      );
    }
  }

  String _friendlyError(Object error) =>
      error is BluetoothReceiptPrinterException
      ? error.message
      : 'Printer setup failed: $error';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth printer setup')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '58 mm Bluetooth test printer',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pair your MPT-II printer in the phone’s Android Bluetooth settings first. TableSideCY lists only already-paired devices and does not request location access.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _loading ? null : _refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Refresh paired printers'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _selected == null ? null : _clearSelection,
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('Clear selection'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            )
          else if (_devices.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No paired Bluetooth devices were found. Turn on the MPT-II, pair it in Android Settings, then refresh.',
                ),
              ),
            )
          else
            Card(
              child: RadioGroup<String>(
                groupValue: _selected?.address,
                onChanged: (address) {
                  if (address == null) return;
                  final device = _devices.firstWhere(
                    (candidate) => candidate.address == address,
                  );
                  _select(device);
                },
                child: Column(
                  children: [
                    for (final device in _devices)
                      RadioListTile<String>(
                        value: device.address,
                        title: Text(device.name),
                        subtitle: Text(device.address),
                        secondary: const Icon(Icons.print_outlined),
                      ),
                  ],
                ),
              ),
            ),
          if (_selected != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<ReceiptPaperWidth>(
                  key: ValueKey(
                    'paper-width-${_selected!.address}-${_selected!.paperWidth.millimetres}',
                  ),
                  initialValue: _selected!.paperWidth,
                  decoration: const InputDecoration(
                    labelText: 'Receipt paper width',
                    helperText:
                        'Choose the physical roll width fitted to this paired printer.',
                  ),
                  items: [
                    for (final width in ReceiptPaperWidth.values)
                      DropdownMenuItem<ReceiptPaperWidth>(
                        value: width,
                        child: Text(width.label),
                      ),
                  ],
                  onChanged: _printing
                      ? null
                      : (width) {
                          if (width != null) _selectPaperWidth(width);
                        },
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live production tickets on this device',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Choose the ticket types for this printer. Saving here enrols this Android device, secures its live queue, and assigns the venue routes automatically. Test and live printing use the same selected Bluetooth printer.',
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable live production printing'),
                    value: _routing.enabled,
                    onChanged: _selected == null || _savingRouting
                        ? null
                        : (enabled) {
                            // Enabling an empty route previously looked
                            // successful but could never print a live ticket.
                            // The explicit master switch therefore starts with
                            // every standard area; staff can immediately remove
                            // areas that belong to another printer below.
                            const allAreas = <String>{
                              'bar',
                              'kitchen',
                              'dessert',
                            };
                            setState(() {
                              _routing = BluetoothProductionRouting(
                                enabled: enabled,
                                productionAreas:
                                    enabled && _routing.productionAreas.isEmpty
                                    ? allAreas
                                    : _routing.productionAreas,
                              );
                            });
                          },
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final area in const [
                        ('bar', 'Bar'),
                        ('kitchen', 'Kitchen'),
                        ('dessert', 'Dessert'),
                        ('receipt', 'Paid receipts'),
                      ])
                        FilterChip(
                          label: Text(area.$2),
                          selected: _routing.productionAreas.contains(area.$1),
                          onSelected: _selected == null || _savingRouting
                              ? null
                              : (selected) {
                                  final areas = {..._routing.productionAreas};
                                  if (selected) {
                                    areas.add(area.$1);
                                  } else {
                                    areas.remove(area.$1);
                                  }
                                  setState(() {
                                    _routing = BluetoothProductionRouting(
                                      enabled: _routing.enabled,
                                      productionAreas: areas,
                                    );
                                  });
                                },
                        ),
                    ],
                  ),
                  if (_selected == null) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Select a paired printer before enabling routing.',
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed:
                            (_routing.enabled &&
                                    _routing.productionAreas.isEmpty) ||
                                _savingRouting
                            ? null
                            : () => _saveRouting(_routing),
                        icon: _savingRouting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.verified_rounded),
                        label: Text(
                          _savingRouting
                              ? 'Securing live printer…'
                              : _routing.enabled
                              ? 'Register and apply live routes'
                              : 'Turn off live printing on this device',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const VenuePrinterRoutingPage(),
                        ),
                      ),
                      icon: const Icon(Icons.route_rounded),
                      label: const Text('Advanced shared routes'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _selected == null || _printing ? null : _testPrint,
            icon: _printing
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.print_rounded),
            label: Text(
              _printing ? 'Sending test ticket…' : 'Print test ticket',
            ),
          ),
        ],
      ),
    );
  }
}
