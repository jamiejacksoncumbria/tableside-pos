import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/date_formats.dart';
import 'bluetooth_receipt_printer.dart';
import 'receipt_paper_width.dart';

BluetoothReceiptPrinter createBluetoothReceiptPrinter() =>
    _NativeBluetoothReceiptPrinter();

class _NativeBluetoothReceiptPrinter implements BluetoothReceiptPrinter {
  static const _namePreferenceKey = 'tableside.bluetoothPrinter.name';
  static const _addressPreferenceKey = 'tableside.bluetoothPrinter.address';
  static const _paperWidthPreferencePrefix =
      'tableside.bluetoothPrinter.paperWidth.';
  static const _routingPreferencePrefix =
      'tableside.bluetoothPrinter.productionRouting.';

  // The package keeps a process-wide Android output stream. Calling its
  // connect API again while that stream is healthy returns false, so retain the
  // address and reuse the live connection for subsequent tickets.
  static String? _connectedAddress;

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<List<BluetoothReceiptPrinterDevice>> pairedDevices() async {
    await _ensureReady();
    final devices = await PrintBluetoothThermal.pairedBluetooths;
    return Future.wait(
      devices.map(
        (device) async => BluetoothReceiptPrinterDevice(
          name: device.name.trim().isEmpty
              ? 'Unnamed Bluetooth printer'
              : device.name,
          address: device.macAdress,
          paperWidth: await _paperWidthFor(device.macAdress),
        ),
      ),
    );
  }

  @override
  Future<BluetoothReceiptPrinterDevice?> selectedDevice() async {
    final address = await _preferences.getString(_addressPreferenceKey);
    if (address == null || address.isEmpty) return null;
    final name = await _preferences.getString(_namePreferenceKey);
    return BluetoothReceiptPrinterDevice(
      name: name?.isNotEmpty == true ? name! : 'Configured Bluetooth printer',
      address: address,
      paperWidth: await _paperWidthFor(address),
    );
  }

  @override
  Future<void> selectDevice(BluetoothReceiptPrinterDevice device) async {
    await _preferences.setString(_namePreferenceKey, device.name);
    await _preferences.setString(_addressPreferenceKey, device.address);
    await _preferences.setInt(
      _paperWidthPreferenceKey(device.address),
      device.paperWidth.millimetres,
    );
  }

  @override
  Future<void> clearSelectedDevice() async {
    await _preferences.remove(_namePreferenceKey);
    await _preferences.remove(_addressPreferenceKey);
  }

  @override
  Future<BluetoothProductionRouting> productionRouting({
    required String venueRoutingKey,
  }) async {
    final raw = await _preferences.getString(
      _routingPreferenceKey(venueRoutingKey),
    );
    if (raw == null || raw.isEmpty) return const BluetoothProductionRouting();
    final parts = raw.split('|');
    return BluetoothProductionRouting(
      enabled: parts.first == 'enabled',
      productionAreas: parts.skip(1).where((area) => area.isNotEmpty).toSet(),
    );
  }

  @override
  Future<void> saveProductionRouting({
    required String venueRoutingKey,
    required BluetoothProductionRouting routing,
  }) {
    final value = [
      routing.enabled ? 'enabled' : 'disabled',
      ...routing.productionAreas.toList()..sort(),
    ].join('|');
    return _preferences.setString(
      _routingPreferenceKey(venueRoutingKey),
      value,
    );
  }

  @override
  Future<void> printTestTicket({
    required BluetoothReceiptPrinterDevice device,
    required String restaurantName,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(device.paperWidth), profile);
    final bytes = <int>[
      ...generator.reset(),
      ...generator.text(
        restaurantName.isEmpty ? 'TABLESIDE POS' : restaurantName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
      ...generator.text(
        'Bluetooth printer test',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
      ...generator.hr(),
      ...generator.text('Printer: ${device.name}'),
      ...generator.text('Address: ${device.address}'),
      ...generator.text('Paper: ${device.paperWidth.label} ESC/POS'),
      ...generator.text('Status: TEST PRINT'),
      ...generator.hr(),
      ...generator.text(
        'If this ticket is clear and complete, Bluetooth printing is ready for configuration.',
        styles: const PosStyles(align: PosAlign.center),
      ),
      ...generator.feed(4),
    ];
    await _write(
      device,
      bytes,
      failureMessage:
          'The printer connection was lost before the test ticket was accepted.',
    );
  }

  @override
  Future<void> printProductionTicket({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothProductionTicket ticket,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(device.paperWidth), profile);
    final location = ticket.tabName?.trim().isNotEmpty == true
        ? 'Tab: ${ticket.tabName!.trim()}'
        : ticket.tableLabel?.trim().isNotEmpty == true
        ? 'Table: ${ticket.tableLabel!.trim()}'
        : 'Order location unavailable';
    final areaLabel = switch (ticket.productionArea) {
      'bar' => 'BAR',
      'dessert' => 'DESSERT',
      _ => 'KITCHEN',
    };
    final ticketHeading = ticket.isReprint
        ? '$areaLabel REPRINT'
        : ticket.isAddition
        ? '$areaLabel ADDITION'
        : areaLabel;
    final printedAt = formatAppDateTime(DateTime.now());
    final bytes = <int>[
      ...generator.reset(),
      ...generator.text(
        ticket.restaurantName.isEmpty ? 'TABLESIDE POS' : ticket.restaurantName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
      ...generator.text(
        ticketHeading,
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
      ...generator.hr(),
      ...generator.text(location, styles: const PosStyles(bold: true)),
      ...generator.text('Order #${ticket.reference}'),
      ...generator.text('Printed: $printedAt'),
      if (ticket.createdByName?.trim().isNotEmpty == true)
        ...generator.text('By: ${ticket.createdByName!.trim()}'),
      ...generator.hr(),
      for (final line in ticket.lines) ...[
        ...generator.text(
          '${line.quantity} x ${line.name}',
          styles: const PosStyles(bold: true),
        ),
        for (final detail in line.details) ...generator.text('  - $detail'),
      ],
      ...generator.hr(),
      ...generator.text(
        ticket.isReprint
            ? 'REPRINT OF EXISTING ORDER'
            : ticket.isAddition
            ? 'ADDITION TO EXISTING ORDER'
            : 'NEW ORDER',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
      ...generator.feed(4),
    ];
    await _write(
      device,
      bytes,
      failureMessage:
          'The printer connection was lost before the production ticket was accepted.',
    );
  }

  @override
  Future<void> printBillReceipt({
    required BluetoothReceiptPrinterDevice device,
    required BluetoothBillReceipt receipt,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(device.paperWidth), profile);
    final location = receipt.tabName?.trim().isNotEmpty == true
        ? 'Tab: ${receipt.tabName!.trim()}'
        : receipt.tableLabel?.trim().isNotEmpty == true
        ? 'Table: ${receipt.tableLabel!.trim()}'
        : null;
    final printedAt = formatAppDateTime(DateTime.now());
    final businessAddressLines = _nonEmptyLines(receipt.businessAddress);
    final businessPhoneNumbers = receipt.businessPhoneNumbers
        .map((number) => number.trim())
        .where((number) => number.isNotEmpty)
        .take(3)
        .toList(growable: false);
    final bytes = <int>[
      ...generator.reset(),
      ...generator.text(
        receipt.restaurantName.isEmpty
            ? 'TABLESIDE POS'
            : receipt.restaurantName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
      for (final line in businessAddressLines)
        ...generator.text(
          line,
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      for (final number in businessPhoneNumbers)
        ...generator.text(
          'Tel: $number',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
      ...generator.text(
        receipt.isPreReceipt
            ? 'PRE RECEIPT - NOT PAID'
            : receipt.isReprint
            ? 'REPRINT - PAID RECEIPT'
            : 'PAID RECEIPT',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
      ...generator.hr(),
      ...generator.text('Receipt: ${receipt.receiptNumber}'),
      if (location != null) ...generator.text(location),
      if (receipt.businessDate?.trim().isNotEmpty == true)
        ...generator.text('Business date: ${receipt.businessDate}'),
      ...generator.text('Printed: $printedAt'),
      ...generator.hr(),
      for (final line in receipt.lines)
        ..._receiptItemBytes(
          generator: generator,
          paperWidth: device.paperWidth,
          description: '${line.name} x${line.quantity}',
          price: _money(line.lineTotalMinor, receipt.currencyCode),
        ),
      ...generator.hr(),
      if (receipt.netTotalMinor != null)
        ...generator.row([
          PosColumn(text: 'Net', width: 6),
          PosColumn(
            text: _money(receipt.netTotalMinor!, receipt.currencyCode),
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      ...generator.row([
        PosColumn(text: 'Tax included', width: 6),
        PosColumn(
          text: _money(receipt.taxTotalMinor, receipt.currencyCode),
          width: 6,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]),
      for (final tax in receipt.taxBreakdown)
        ...generator.text(
          '${tax.name} (${_percentage(tax.basisPoints)}): ${_money(tax.taxMinor, receipt.currencyCode)}',
        ),
      ...generator.row([
        PosColumn(text: 'TOTAL', width: 6, styles: const PosStyles(bold: true)),
        PosColumn(
          text: _money(receipt.totalMinor, receipt.currencyCode),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]),
      if (receipt.payments.isNotEmpty) ...[
        ...generator.hr(),
        ...generator.text('Payments', styles: const PosStyles(bold: true)),
        for (final payment in receipt.payments) ...[
          ...generator.text(
            '${payment.method}${payment.terminalLabel?.trim().isNotEmpty == true ? ' (${payment.terminalLabel!.trim()})' : ''}: ${_money(payment.amountMinor, payment.currencyCode)}',
          ),
          if (payment.currencyCode != payment.baseCurrencyCode &&
              payment.baseAmountMinor != null) ...[
            ...generator.text(
              'Rate: 1 ${payment.currencyCode} = ${payment.exchangeRateToBase} ${payment.baseCurrencyCode}',
            ),
            ...generator.text(
              'Applied: ${_money(payment.baseAmountMinor!, payment.baseCurrencyCode!)}',
            ),
          ],
          if (payment.changeBaseMinor > 0)
            ...generator.text(
              'Change: ${_money(payment.changeBaseMinor, payment.baseCurrencyCode ?? receipt.currencyCode)}',
            ),
          if (payment.exchangeRateSource?.trim().isNotEmpty == true)
            ...generator.text(
              'Rate source: ${payment.exchangeRateSource!.trim()}',
            ),
        ],
      ],
      if (receipt.receiptFooter.trim().isNotEmpty) ...[
        ...generator.hr(),
        ...generator.text(
          receipt.receiptFooter.trim(),
          styles: const PosStyles(align: PosAlign.center),
        ),
      ],
      ...generator.feed(4),
    ];
    await _write(
      device,
      bytes,
      failureMessage:
          'The printer connection was lost before the paid receipt was accepted.',
    );
  }

  @override
  Future<void> printTextReport({
    required BluetoothReceiptPrinterDevice device,
    required String title,
    required List<String> lines,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(device.paperWidth), profile);
    final bytes = <int>[
      ...generator.reset(),
      ...generator.text(
        title,
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ),
      ...generator.hr(),
      for (final line in lines) ...generator.text(line),
      ...generator.feed(4),
    ];
    await _write(
      device,
      bytes,
      failureMessage:
          'The printer connection was lost while printing the report.',
    );
  }

  String _money(int minor, String currencyCode) {
    final negative = minor < 0;
    final absolute = minor.abs();
    final major = absolute ~/ 100;
    final remainder = absolute % 100;
    return '${negative ? '-' : ''}$currencyCode $major.${remainder.toString().padLeft(2, '0')}';
  }

  String _percentage(int basisPoints) {
    final percentage = basisPoints / 100;
    return percentage == percentage.roundToDouble()
        ? '${percentage.toStringAsFixed(0)}%'
        : '${percentage.toStringAsFixed(2)}%';
  }

  List<String> _nonEmptyLines(String value) => value
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  List<int> _receiptItemBytes({
    required Generator generator,
    required ReceiptPaperWidth paperWidth,
    required String description,
    required String price,
  }) {
    final nameColumnWidth = paperWidth.isNarrow ? 7 : 8;
    final priceColumnWidth = 12 - nameColumnWidth;
    final maximumNameCharacters = paperWidth.isNarrow ? 18 : 30;
    final wrappedDescription = _wrapReceiptText(
      description,
      maximumNameCharacters,
    );
    final bytes = <int>[];
    for (final line in wrappedDescription.take(wrappedDescription.length - 1)) {
      bytes.addAll(generator.text(line));
    }
    bytes.addAll(
      generator.row([
        PosColumn(text: wrappedDescription.last, width: nameColumnWidth),
        PosColumn(
          text: price,
          width: priceColumnWidth,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]),
    );
    return bytes;
  }

  List<String> _wrapReceiptText(String value, int maximumCharacters) {
    final words = value.trim().split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      if (word.length > maximumCharacters) {
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        for (var index = 0; index < word.length; index += maximumCharacters) {
          lines.add(
            word.substring(
              index,
              (index + maximumCharacters).clamp(0, word.length),
            ),
          );
        }
        continue;
      }
      final candidate = current.isEmpty ? word : '$current $word';
      if (candidate.length > maximumCharacters && current.isNotEmpty) {
        lines.add(current);
        current = word;
      } else {
        current = candidate;
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines.isEmpty ? const ['Item'] : lines;
  }

  String _routingPreferenceKey(String venueRoutingKey) =>
      '$_routingPreferencePrefix$venueRoutingKey';

  Future<ReceiptPaperWidth> _paperWidthFor(String address) async =>
      ReceiptPaperWidth.fromMillimetres(
        await _preferences.getInt(_paperWidthPreferenceKey(address)),
      );

  String _paperWidthPreferenceKey(String address) =>
      '$_paperWidthPreferencePrefix${Uri.encodeComponent(address)}';

  PaperSize _paperSize(ReceiptPaperWidth paperWidth) =>
      paperWidth.isNarrow ? PaperSize.mm58 : PaperSize.mm80;

  Future<void> _write(
    BluetoothReceiptPrinterDevice device,
    List<int> bytes, {
    required String failureMessage,
  }) async {
    await _ensureConnected(device);
    final written = await PrintBluetoothThermal.writeBytes(bytes);
    if (written) return;

    _connectedAddress = null;
    await PrintBluetoothThermal.disconnect;
    throw BluetoothReceiptPrinterException(failureMessage);
  }

  Future<void> _ensureConnected(BluetoothReceiptPrinterDevice device) async {
    await _ensureReady();
    final alreadyConnected = await PrintBluetoothThermal.connectionStatus;
    if (alreadyConnected && _connectedAddress == device.address) return;

    if (alreadyConnected) {
      await PrintBluetoothThermal.disconnect;
      _connectedAddress = null;
    }
    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: device.address,
    );
    if (!connected) {
      throw const BluetoothReceiptPrinterException(
        'Could not connect to the paired printer. Check it is powered on, nearby, and not connected to another device.',
      );
    }
    _connectedAddress = device.address;
  }

  Future<void> _ensureReady() async {
    if (!isSupported) {
      throw const BluetoothReceiptPrinterException(
        'Bluetooth receipt printing is supported only by the native Android app.',
      );
    }
    if (Platform.isAndroid) {
      final permissions = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();
      final connectPermission =
          permissions[Permission.bluetoothConnect] ?? PermissionStatus.denied;
      final scanPermission =
          permissions[Permission.bluetoothScan] ?? PermissionStatus.denied;
      if (!connectPermission.isGranted || !scanPermission.isGranted) {
        throw const BluetoothReceiptPrinterException(
          'Nearby devices permission is required to use a paired Bluetooth printer. Allow Bluetooth connection and scan access in Android Settings, then try again.',
        );
      }
    }
    final enabled = await PrintBluetoothThermal.bluetoothEnabled;
    if (!enabled) {
      throw const BluetoothReceiptPrinterException(
        'Turn on Bluetooth, pair the printer in Android Settings, then refresh this list.',
      );
    }
  }
}
