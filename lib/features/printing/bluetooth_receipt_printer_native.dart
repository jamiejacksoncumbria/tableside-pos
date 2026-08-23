import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bluetooth_receipt_printer.dart';

BluetoothReceiptPrinter createBluetoothReceiptPrinter() =>
    _NativeBluetoothReceiptPrinter();

class _NativeBluetoothReceiptPrinter implements BluetoothReceiptPrinter {
  static const _namePreferenceKey = 'tableside.bluetoothPrinter.name';
  static const _addressPreferenceKey = 'tableside.bluetoothPrinter.address';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  bool get isSupported => Platform.isAndroid || Platform.isWindows;

  @override
  Future<List<BluetoothReceiptPrinterDevice>> pairedDevices() async {
    await _ensureReady();
    final devices = await PrintBluetoothThermal.pairedBluetooths;
    return devices
        .map(
          (device) => BluetoothReceiptPrinterDevice(
            name: device.name.trim().isEmpty
                ? 'Unnamed Bluetooth printer'
                : device.name,
            address: device.macAdress,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<BluetoothReceiptPrinterDevice?> selectedDevice() async {
    final address = await _preferences.getString(_addressPreferenceKey);
    if (address == null || address.isEmpty) return null;
    final name = await _preferences.getString(_namePreferenceKey);
    return BluetoothReceiptPrinterDevice(
      name: name?.isNotEmpty == true ? name! : 'Configured Bluetooth printer',
      address: address,
    );
  }

  @override
  Future<void> selectDevice(BluetoothReceiptPrinterDevice device) async {
    await _preferences.setString(_namePreferenceKey, device.name);
    await _preferences.setString(_addressPreferenceKey, device.address);
  }

  @override
  Future<void> clearSelectedDevice() async {
    await _preferences.remove(_namePreferenceKey);
    await _preferences.remove(_addressPreferenceKey);
  }

  @override
  Future<void> printTestTicket({
    required BluetoothReceiptPrinterDevice device,
    required String restaurantName,
  }) async {
    await _ensureReady();
    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: device.address,
    );
    if (!connected) {
      throw const BluetoothReceiptPrinterException(
        'Could not connect to the paired printer. Check it is powered on, nearby, and not connected to another device.',
      );
    }

    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
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
      ...generator.text('Paper: 58 mm ESC/POS'),
      ...generator.text('Status: TEST PRINT'),
      ...generator.hr(),
      ...generator.text(
        'If this ticket is clear and complete, Bluetooth printing is ready for configuration.',
        styles: const PosStyles(align: PosAlign.center),
      ),
      ...generator.feed(4),
    ];
    final written = await PrintBluetoothThermal.writeBytes(bytes);
    if (!written) {
      throw const BluetoothReceiptPrinterException(
        'The printer connection was lost before the test ticket was accepted.',
      );
    }
  }

  Future<void> _ensureReady() async {
    if (!isSupported) {
      throw const BluetoothReceiptPrinterException(
        'Bluetooth receipt printing is supported only by the native Android or Windows app.',
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
