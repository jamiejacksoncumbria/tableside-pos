import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_factory.dart';

class BluetoothPrinterSetupPage extends StatefulWidget {
  const BluetoothPrinterSetupPage({super.key, required this.restaurantName});

  final String restaurantName;

  @override
  State<BluetoothPrinterSetupPage> createState() =>
      _BluetoothPrinterSetupPageState();
}

class _BluetoothPrinterSetupPageState extends State<BluetoothPrinterSetupPage> {
  final BluetoothReceiptPrinter _printer = createBluetoothReceiptPrinter();

  List<BluetoothReceiptPrinterDevice> _devices = const [];
  BluetoothReceiptPrinterDevice? _selected;
  bool _loading = true;
  bool _printing = false;
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
            'Bluetooth receipt printing is available only in the native Android or Windows app.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = await _printer.selectedDevice();
      final devices = await _printer.pairedDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _selected = devices.cast<BluetoothReceiptPrinterDevice?>().firstWhere(
          (device) => device?.address == selected?.address,
          orElse: () => selected,
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${device.name} is selected for test printing.'),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Select Bluetooth printer', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(error))));
    }
  }

  Future<void> _clearSelection() async {
    try {
      await _printer.clearSelectedDevice();
      if (mounted) setState(() => _selected = null);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Clear Bluetooth printer selection', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(error))));
    }
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Test bytes were sent. Confirm that the complete ticket printed before enabling live routes.',
          ),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Bluetooth test print', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(error))));
    } finally {
      if (mounted) setState(() => _printing = false);
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
                    'Pair your MPT-II printer in the phone’s Android Bluetooth settings first. TableSide lists only already-paired devices and does not request location access.',
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
