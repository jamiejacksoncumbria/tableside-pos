import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'windows_print_queue.dart';
import 'receipt_paper_width.dart';

WindowsPrintQueue createWindowsPrintQueue() => _NativeWindowsPrintQueue();

class _NativeWindowsPrintQueue implements WindowsPrintQueue {
  static const _channel = MethodChannel('tableside/windows_printer');
  static const _namePreferenceKey = 'tableside.windowsPrinter.name';
  static const _driverPreferenceKey = 'tableside.windowsPrinter.driver';
  static const _portPreferenceKey = 'tableside.windowsPrinter.port';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<List<WindowsPrintQueueDevice>> installedPrinters() async {
    _ensureSupported();
    try {
      final response = await _channel.invokeMethod<List<Object?>>(
        'listPrinters',
      );
      final queues = (response ?? const <Object?>[])
          .whereType<Map>()
          .map((raw) {
            final printer = Map<String, Object?>.from(raw);
            final name = printer['name'] as String? ?? '';
            if (name.trim().isEmpty) {
              throw const WindowsPrintQueueException(
                'Windows returned an installed printer without a name.',
              );
            }
            return WindowsPrintQueueDevice(
              name: name,
              driverName: printer['driverName'] as String? ?? '',
              portName: printer['portName'] as String? ?? '',
              isDefault: printer['isDefault'] == true,
            );
          })
          .toList(growable: false);
      final storedWidths = await Future.wait(
        queues.map(
          (printer) async =>
              printer.copyWith(paperWidth: await _paperWidthFor(printer.name)),
        ),
      );
      return storedWidths..sort((left, right) {
        if (left.isDefault != right.isDefault) {
          return left.isDefault ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
    } on MissingPluginException {
      throw const WindowsPrintQueueException(
        'Windows printer support was added after this app started. Stop the Windows app completely and run it again so the native printer component is loaded.',
      );
    } on PlatformException catch (error) {
      throw WindowsPrintQueueException(
        error.message ?? 'Windows could not list installed printers.',
      );
    }
  }

  @override
  Future<WindowsPrintQueueDevice?> selectedPrinter() async {
    final name = await _preferences.getString(_namePreferenceKey);
    if (name == null || name.trim().isEmpty) return null;
    return WindowsPrintQueueDevice(
      name: name,
      driverName: await _preferences.getString(_driverPreferenceKey) ?? '',
      portName: await _preferences.getString(_portPreferenceKey) ?? '',
      isDefault: false,
      paperWidth: await _paperWidthFor(name),
    );
  }

  @override
  Future<void> selectPrinter(WindowsPrintQueueDevice printer) async {
    _ensureSupported();
    await _preferences.setString(_namePreferenceKey, printer.name);
    await _preferences.setString(_driverPreferenceKey, printer.driverName);
    await _preferences.setString(_portPreferenceKey, printer.portName);
    await _preferences.setInt(
      _paperWidthPreferenceKey(printer.name),
      printer.paperWidth.millimetres,
    );
  }

  @override
  Future<void> clearSelectedPrinter() async {
    await _preferences.remove(_namePreferenceKey);
    await _preferences.remove(_driverPreferenceKey);
    await _preferences.remove(_portPreferenceKey);
  }

  @override
  Future<void> printText({
    required WindowsPrintQueueDevice printer,
    required String title,
    required List<String> lines,
  }) async {
    _ensureSupported();
    if (lines.isEmpty) {
      throw const WindowsPrintQueueException('A print job must contain text.');
    }
    try {
      await _channel.invokeMethod<void>('printText', {
        'printerName': printer.name,
        'title': title,
        'lines': lines,
        'paperWidthMm': printer.paperWidth.millimetres,
      });
    } on MissingPluginException {
      throw const WindowsPrintQueueException(
        'Windows printer support was added after this app started. Stop the Windows app completely and run it again so the native printer component is loaded.',
      );
    } on PlatformException catch (error) {
      throw WindowsPrintQueueException(
        error.message ?? 'Windows could not send the receipt to the printer.',
      );
    }
  }

  @override
  Future<void> printTestTicket({
    required WindowsPrintQueueDevice printer,
    required String restaurantName,
  }) {
    return printText(
      printer: printer,
      title: 'TableSide printer test',
      lines: [
        restaurantName.trim().isEmpty ? 'TABLESIDE POS' : restaurantName,
        '',
        'WINDOWS PRINTER TEST',
        'Queue: ${printer.name}',
        if (printer.driverName.trim().isNotEmpty)
          'Driver: ${printer.driverName}',
        if (printer.portName.trim().isNotEmpty) 'Port: ${printer.portName}',
        'TableSide layout: ${printer.paperWidth.label}',
        '',
        'If this ticket is clear and complete, this Windows printer is ready for TableSide routes.',
      ],
    );
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw const WindowsPrintQueueException(
        'Windows USB and network printer support is available only in the Windows desktop app.',
      );
    }
  }

  Future<ReceiptPaperWidth> _paperWidthFor(String printerName) async =>
      ReceiptPaperWidth.fromMillimetres(
        await _preferences.getInt(_paperWidthPreferenceKey(printerName)),
      );

  String _paperWidthPreferenceKey(String printerName) =>
      'tableside.windowsPrinter.paperWidth.${Uri.encodeComponent(printerName)}';
}
