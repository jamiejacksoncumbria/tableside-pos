import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../notifications/notification_centre.dart';
import 'windows_print_queue.dart';
import 'windows_print_queue_factory.dart';
import 'receipt_paper_width.dart';

/// Chooses a Windows-installed queue for this physical PC. A USB receipt
/// printer and a network printer need no different TableSide setup: install
/// their Windows driver/port first, then choose its queue here.
class WindowsPrinterSetupPage extends StatefulWidget {
  const WindowsPrinterSetupPage({super.key, required this.restaurantName});

  final String restaurantName;

  @override
  State<WindowsPrinterSetupPage> createState() =>
      _WindowsPrinterSetupPageState();
}

class _WindowsPrinterSetupPageState extends State<WindowsPrinterSetupPage> {
  final WindowsPrintQueue _printer = createWindowsPrintQueue();

  List<WindowsPrintQueueDevice> _printers = const [];
  WindowsPrintQueueDevice? _selected;
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
            'Windows USB and network printer support is available only in the Windows desktop app.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = await _printer.selectedPrinter();
      final printers = await _printer.installedPrinters();
      if (!mounted) return;
      setState(() {
        _printers = printers;
        final matching = printers.where(
          (printer) => printer.name == selected?.name,
        );
        _selected = matching.isEmpty
            ? selected
            : matching.first.copyWith(paperWidth: selected?.paperWidth);
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load installed Windows printers', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(WindowsPrintQueueDevice printer) async {
    try {
      await _printer.selectPrinter(printer);
      if (!mounted) return;
      setState(() => _selected = printer);
      showAppNotification(
        context,
        title: 'Windows printer selected',
        message: '${printer.name} is selected for test printing and routes.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Select Windows printer', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Could not select Windows printer',
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

  Future<void> _clearSelection() async {
    try {
      await _printer.clearSelectedPrinter();
      if (mounted) setState(() => _selected = null);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Clear Windows printer selection', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Could not clear printer selection',
        message: _friendlyError(error),
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _testPrint() async {
    final selected = _selected;
    if (selected == null || _printing) return;
    setState(() => _printing = true);
    try {
      await _printer.printTestTicket(
        printer: selected,
        restaurantName: widget.restaurantName,
      );
      if (!mounted) return;
      showAppNotification(
        context,
        title: 'Test print sent',
        message:
            'Windows accepted the test job. Confirm the complete ticket printed before enabling live routes.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Windows printer test print', error, stackTrace);
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

  String _friendlyError(Object error) => error is WindowsPrintQueueException
      ? error.message
      : 'Windows printer setup failed: $error';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Windows printer setup')),
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
                    'USB and network receipt printers',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Install the printer in Windows first. A USB printer and a network printer are both listed here as Windows print queues. Set the correct 58 mm or 80 mm paper and cutter settings in Windows Printer preferences.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _loading ? null : _refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Refresh installed printers'),
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
          else if (_printers.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Windows did not return any installed printers. Check the SAM4S driver installation, printer power and Windows Settings > Bluetooth & devices > Printers & scanners, then refresh.',
                ),
              ),
            )
          else
            Card(
              child: RadioGroup<String>(
                groupValue: _selected?.name,
                onChanged: (name) {
                  if (name == null) return;
                  _select(
                    _printers.firstWhere((printer) => printer.name == name),
                  );
                },
                child: Column(
                  children: [
                    for (final printer in _printers)
                      RadioListTile<String>(
                        value: printer.name,
                        title: Text(printer.name),
                        subtitle: Text(
                          [
                            if (printer.isDefault) 'Windows default',
                            if (printer.driverName.isNotEmpty)
                              printer.driverName,
                            if (printer.portName.isNotEmpty) printer.portName,
                          ].join(' · '),
                        ),
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
                    'paper-width-${_selected!.name}-${_selected!.paperWidth.millimetres}',
                  ),
                  initialValue: _selected!.paperWidth,
                  decoration: const InputDecoration(
                    labelText: 'TableSide receipt paper width',
                    helperText:
                        'This must match the paper size selected in Windows printer preferences.',
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
