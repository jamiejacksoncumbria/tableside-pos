import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/printer_device_repository.dart';
import '../../data/printer_route_repository.dart';
import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';
import 'local_printer_device_identity.dart';
import 'windows_print_queue.dart';
import 'windows_print_queue_factory.dart';

/// A manager-only venue configuration page. The Firestore rules enforce the
/// permission as well, so a waiter cannot create a route by calling the API
/// directly.
class VenuePrinterRoutingPage extends ConsumerStatefulWidget {
  const VenuePrinterRoutingPage({super.key});

  @override
  ConsumerState<VenuePrinterRoutingPage> createState() =>
      _VenuePrinterRoutingPageState();
}

class _VenuePrinterRoutingPageState
    extends ConsumerState<VenuePrinterRoutingPage> {
  final PrinterDeviceRepository _devices = PrinterDeviceRepository(
    FirebaseFirestore.instance,
  );
  final PrinterRouteRepository _routes = PrinterRouteRepository(
    FirebaseFirestore.instance,
  );
  final LocalPrinterDeviceIdentity _identity = LocalPrinterDeviceIdentity();
  final BluetoothReceiptPrinter _bluetooth = createBluetoothReceiptPrinter();
  final WindowsPrintQueue _windowsPrinter = createWindowsPrintQueue();
  final TextEditingController _deviceName = TextEditingController();

  String? _deviceId;
  String? _assignedUserId;
  BluetoothReceiptPrinterDevice? _selectedBluetoothPrinter;
  WindowsPrintQueueDevice? _selectedWindowsPrinter;
  bool _loading = true;
  bool _registering = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLocalDevice();
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _loadLocalDevice() async {
    try {
      final deviceId = await _identity.getOrCreate();
      final selectedPrinter = _bluetooth.isSupported
          ? await _bluetooth.selectedDevice()
          : null;
      final selectedWindowsPrinter = _windowsPrinter.isSupported
          ? await _windowsPrinter.selectedPrinter()
          : null;
      if (!mounted) return;
      setState(() {
        _deviceId = deviceId;
        _assignedUserId = FirebaseAuth.instance.currentUser?.uid;
        _selectedBluetoothPrinter = selectedPrinter;
        _selectedWindowsPrinter = selectedWindowsPrinter;
        if (_deviceName.text.trim().isEmpty) {
          _deviceName.text =
              selectedWindowsPrinter?.name ?? selectedPrinter?.name ?? '';
        }
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load local printer device identity', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _registerThisDevice({
    required VenueScope scope,
    required String assignedUserId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final deviceId = _deviceId;
    if (user == null || deviceId == null) {
      setState(() => _error = 'Sign in and wait for device setup to finish.');
      return;
    }
    final transports = <String>[
      if (_selectedBluetoothPrinter != null) 'bluetooth',
      if (_selectedWindowsPrinter != null) 'windowsPrintQueue',
    ];
    if (transports.isEmpty) {
      setState(
        () => _error =
            'Select a Bluetooth printer on Android or a Windows print queue before registering this device.',
      );
      return;
    }
    final name = _deviceName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a device name.');
      return;
    }
    setState(() {
      _registering = true;
      _error = null;
    });
    try {
      await _devices.register(
        PrinterDevice(
          id: deviceId,
          venueId: scope.venueId,
          name: name,
          platform: _platformName(),
          productionAreas: productionRouteAreas,
          transports: transports,
          assignedUserId: assignedUserId,
          active: true,
        ),
        tenantId: scope.tenantId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This device is registered as a shared venue printer.'),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Register shared printer device', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  String _platformName() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.windows => 'windows',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };

  Future<void> _editRoute({
    required VenueScope scope,
    required String area,
    required List<PrinterDevice> devices,
    PrinterRoute? existing,
  }) async {
    final eligibleDevices = devices
        .where((device) => device.productionAreas.contains(area))
        .toList(growable: false);
    final availableIds = eligibleDevices.map((device) => device.id).toSet();
    var primaryDeviceId = availableIds.contains(existing?.primaryDeviceId)
        ? existing?.primaryDeviceId
        : null;
    var fallbackDeviceId = availableIds.contains(existing?.fallbackDeviceId)
        ? existing?.fallbackDeviceId
        : null;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${_areaLabel(area)} printer route'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: primaryDeviceId,
                decoration: const InputDecoration(labelText: 'Primary printer'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No shared printer'),
                  ),
                  for (final device in eligibleDevices)
                    DropdownMenuItem<String?>(
                      value: device.id,
                      child: Text(device.name),
                    ),
                ],
                onChanged: (value) => setDialogState(() {
                  primaryDeviceId = value;
                  if (fallbackDeviceId == value) fallbackDeviceId = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: fallbackDeviceId,
                decoration: const InputDecoration(
                  labelText: 'Fallback printer',
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No fallback printer'),
                  ),
                  for (final device in eligibleDevices.where(
                    (device) => device.id != primaryDeviceId,
                  ))
                    DropdownMenuItem<String?>(
                      value: device.id,
                      child: Text(device.name),
                    ),
                ],
                onChanged: primaryDeviceId == null
                    ? null
                    : (value) => setDialogState(() => fallbackDeviceId = value),
              ),
              const SizedBox(height: 12),
              Text(
                eligibleDevices.isEmpty
                    ? 'No registered device supports this route yet. Re-register the relevant device so it can handle ${_areaLabel(area).toLowerCase()} tickets.'
                    : 'A failed printer retries three times before the fallback device is used.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await _routes.saveRoute(
                    scope: scope,
                    productionArea: area,
                    primaryDeviceId: primaryDeviceId,
                    fallbackDeviceId: fallbackDeviceId,
                  );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                } on Object catch (error, stackTrace) {
                  AppLogger.error('Save printer route', error, stackTrace);
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('Could not save route: $error')),
                    );
                  }
                }
              },
              child: const Text('Save route'),
            ),
          ],
        ),
      ),
    );
  }

  String _areaLabel(String area) => switch (area) {
    'bar' => 'Bar',
    'dessert' => 'Dessert',
    'receipt' => 'Paid receipt',
    _ => 'Kitchen',
  };

  Stream<List<_VenueMember>> _watchActiveMembers() {
    final user = FirebaseAuth.instance.currentUser;
    return Stream.value(
      user == null
          ? const <_VenueMember>[]
          : <_VenueMember>[
              _VenueMember(
                userId: user.uid,
                email: user.email ?? '',
                active: true,
              ),
            ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) {
      return const Scaffold(
        body: Center(
          child: Text('Choose a venue before configuring printers.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Venue printer routes')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Shared printer device',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Register this physical Android or Windows device to receive queued tickets for the selected venue.',
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: StreamBuilder<List<_VenueMember>>(
                      stream: _watchActiveMembers(),
                      builder: (context, memberSnapshot) {
                        final members =
                            memberSnapshot.data ?? const <_VenueMember>[];
                        final selectedUserId =
                            members.any(
                              (member) => member.userId == _assignedUserId,
                            )
                            ? _assignedUserId
                            : null;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _deviceName,
                              decoration: const InputDecoration(
                                labelText: 'Device name',
                                hintText: 'Kitchen printer terminal',
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (_selectedWindowsPrinter != null)
                              Text(
                                'Windows print queue: ${_selectedWindowsPrinter!.name}',
                              )
                            else if (_selectedBluetoothPrinter != null)
                              Text(
                                'Bluetooth printer: ${_selectedBluetoothPrinter!.name}',
                              )
                            else
                              const Text(
                                'No printer selected on this device. Configure Bluetooth on Android or a Windows print queue before registering.',
                              ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String?>(
                              key: ValueKey('assigned-user-$selectedUserId'),
                              initialValue: selectedUserId,
                              decoration: const InputDecoration(
                                labelText: 'Firebase device account',
                                helperText:
                                    'This is the signed-in account used by this physical device to claim queued tickets.',
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('Select a venue user'),
                                ),
                                for (final member in members)
                                  DropdownMenuItem<String?>(
                                    value: member.userId,
                                    child: Text(member.label),
                                  ),
                              ],
                              onChanged: null,
                            ),
                            if (memberSnapshot.hasError) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Could not load venue users: ${memberSnapshot.error}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _registering || selectedUserId == null
                                  ? null
                                  : () => _registerThisDevice(
                                      scope: scope,
                                      assignedUserId: selectedUserId,
                                    ),
                              icon: const Icon(Icons.devices_rounded),
                              label: Text(
                                _registering
                                    ? 'Registering…'
                                    : 'Register this shared printer device',
                              ),
                            ),
                            if (_deviceId != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Device ID: ${_deviceId!.substring(0, 15)}…',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Ticket and receipt routing',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Orders and paid receipts are queued by the server after it validates stock, the menu and payment. Choose a primary and optional fallback device for each route.',
                ),
                const SizedBox(height: 12),
                StreamBuilder<List<PrinterDevice>>(
                  stream: _devices.watchVenueDevices(
                    tenantId: scope.tenantId,
                    venueId: scope.venueId,
                  ),
                  builder: (context, deviceSnapshot) {
                    if (deviceSnapshot.hasError) {
                      return Text(
                        'Could not load printer devices: ${deviceSnapshot.error}',
                      );
                    }
                    final devices =
                        (deviceSnapshot.data ?? const <PrinterDevice>[])
                            .where((device) => device.active)
                            .toList(growable: false);
                    return StreamBuilder<List<PrinterRoute>>(
                      stream: _routes.watchVenueRoutes(scope),
                      builder: (context, routeSnapshot) {
                        if (routeSnapshot.hasError) {
                          return Text(
                            'Could not load printer routes: ${routeSnapshot.error}',
                          );
                        }
                        final routes = {
                          for (final route
                              in routeSnapshot.data ?? const <PrinterRoute>[])
                            route.productionArea: route,
                        };
                        if (devices.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'Register at least one printer device before assigning routes.',
                              ),
                            ),
                          );
                        }
                        return Column(
                          children: [
                            for (final area in productionRouteAreas)
                              Card(
                                child: ListTile(
                                  leading: Icon(switch (area) {
                                    'bar' => Icons.local_bar_rounded,
                                    'dessert' => Icons.cake_outlined,
                                    'receipt' => Icons.receipt_long_outlined,
                                    _ => Icons.restaurant_rounded,
                                  }),
                                  title: Text(_areaLabel(area)),
                                  subtitle: Text(
                                    _routeSummary(routes[area], devices),
                                  ),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                  ),
                                  onTap: () => _editRoute(
                                    scope: scope,
                                    area: area,
                                    devices: devices,
                                    existing: routes[area],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ],
            ),
    );
  }

  String _routeSummary(PrinterRoute? route, List<PrinterDevice> devices) {
    final primaryId = route?.primaryDeviceId;
    if (primaryId == null) return 'No shared printer configured';
    final primary = devices
        .where((device) => device.id == primaryId)
        .map((device) => device.name)
        .firstOrNull;
    final fallback = devices
        .where((device) => device.id == route?.fallbackDeviceId)
        .map((device) => device.name)
        .firstOrNull;
    return fallback == null
        ? 'Primary: ${primary ?? 'Unavailable device'}'
        : 'Primary: ${primary ?? 'Unavailable device'} · Fallback: $fallback';
  }
}

class _VenueMember {
  const _VenueMember({
    required this.userId,
    required this.email,
    required this.active,
  });

  final String userId;
  final String email;
  final bool active;

  String get label => email.isEmpty ? userId : email;
}
