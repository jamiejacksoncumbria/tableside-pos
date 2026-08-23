import 'bluetooth_receipt_printer.dart';
import 'bluetooth_receipt_printer_stub.dart'
    if (dart.library.io) 'bluetooth_receipt_printer_native.dart'
    as implementation;

BluetoothReceiptPrinter createBluetoothReceiptPrinter() =>
    implementation.createBluetoothReceiptPrinter();
