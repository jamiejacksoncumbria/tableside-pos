import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/printer_device_repository.dart';
import '../../data/printer_route_repository.dart';
import '../auth/staff_pin_gate.dart';
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
  BluetoothReceiptPrinterDevice? _selectedBluetoothPrinter;
  WindowsPrintQueueDevice? _selectedWindowsPrinter;
  bool _loading = true;
  bool _registering = false;
  final Set<String> _removingDeviceIds = <String>{};
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
      final physicalDeviceId = await _identity.getOrCreate();
      final selectedPrinter = _bluetooth.isSupported
          ? await _bluetooth.selectedDevice()
          : null;
      final selectedWindowsPrinter = _windowsPrinter.isSupported
          ? await _windowsPrinter.selectedPrinter()
          : null;
      if (!mounted) return;
      setState(() {
        _deviceId = physicalDeviceId;
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

  Future<void> _registerThisDevice({required VenueScope scope}) async {
    final user = FirebaseAuth.instance.currentUser;
    final physicalDeviceId = _deviceId;
    if (user == null || physicalDeviceId == null) {
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
      final deviceId = await _identity.deviceIdForScope(scope);
      final hasSession = ref
          .read(activeStaffPinSessionProvider.notifier)
          .restoreCredentials();
      if (!hasSession) {
        throw StateError(
          'Your staff PIN session expired. Enter your PIN again.',
        );
      }
      final deviceCredential = await _devices.register(
        PrinterDevice(
          id: deviceId,
          venueId: scope.venueId,
          name: name,
          platform: _platformName(),
          productionAreas: productionRouteAreas,
          transports: transports,
          active: true,
        ),
        tenantId: scope.tenantId,
      );
      await _identity.saveCredential(scope, deviceCredential);
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

  Future<void> _removeDevice({
    required VenueScope scope,
    required PrinterDevice device,
  }) async {
    final localDeviceId = await _identity.deviceIdForScope(scope);
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${device.name}?'),
        content: Text(
          device.id == localDeviceId
              ? 'This registration and its local credential will be reset. Any routes using it will be repaired. Queued or printing tickets must be cleared first.'
              : 'This stale registration will be archived. Any routes using it will be repaired. Queued or printing tickets must be cleared first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Remove device'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    setState(() {
      _removingDeviceIds.add(device.id);
      _error = null;
    });
    try {
      final hasSession = ref
          .read(activeStaffPinSessionProvider.notifier)
          .restoreCredentials();
      if (!hasSession) {
        throw StateError(
          'Your staff PIN session expired. Enter your PIN again.',
        );
      }
      await _devices.remove(scope: scope, deviceId: device.id);
      if (device.id == localDeviceId) {
        await _identity.clearCredential(scope);
        if (mounted) {
          setState(() {
            // Keep the local Bluetooth/Windows selection intact. It belongs
            // to this physical device and can be reused if the manager later
            // registers it again for this venue or another venue.
            _deviceName.clear();
          });
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${device.name} was removed safely.')),
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Remove printer device', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _removingDeviceIds.remove(device.id));
    }
  }

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
                  final hasSession = ref
                      .read(activeStaffPinSessionProvider.notifier)
                      .restoreCredentials();
                  if (!hasSession) {
                    throw StateError(
                      'Your staff PIN session expired. Enter your PIN again.',
                    );
                  }
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
    final staffSession = ref.watch(activeStaffPinSessionProvider);
    if (staffSession == null ||
        !staffSession.expiresAt.isAfter(DateTime.now())) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(
        body: Center(child: Text('Staff PIN expired. Returning to sign-in…')),
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
                    child: Column(
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
                        FilledButton.icon(
                          onPressed: _registering
                              ? null
                              : () => _registerThisDevice(scope: scope),
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
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Registered devices',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(height: 6),
                            for (final device in devices)
                              Card(
                                child: ListTile(
                                  leading: Icon(
                                    device.id == _deviceId
                                        ? Icons.devices_rounded
                                        : Icons.print_outlined,
                                  ),
                                  title: Text(device.name),
                                  subtitle: Text(
                                    '${device.platform}${device.id == _deviceId ? ' · This device' : ''}',
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Remove printer device',
                                    onPressed:
                                        _removingDeviceIds.contains(device.id)
                                        ? null
                                        : () => _removeDevice(
                                            scope: scope,
                                            device: device,
                                          ),
                                    icon: _removingDeviceIds.contains(device.id)
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.delete_outline_rounded,
                                          ),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Routes',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(height: 6),
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
