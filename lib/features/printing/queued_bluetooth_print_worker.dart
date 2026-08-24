import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import '../../data/printer_device_repository.dart';
import 'local_printer_device_identity.dart';
import 'native_print_worker.dart';
import 'queued_bluetooth_receipt_printer.dart';

/// Runs only in a foreground native app session. Android boot/background
/// services are a later device-agent step; this worker gives each registered
/// Android or Windows device reliable foreground queue processing now.
class QueuedBluetoothPrintWorker {
  QueuedBluetoothPrintWorker({
    PrintJobRepository? queue,
    PrinterDeviceRepository? devices,
    LocalPrinterDeviceIdentity? identity,
  }) : _queue = queue ?? PrintJobRepository(FirebaseFirestore.instance),
       _devices =
           devices ?? PrinterDeviceRepository(FirebaseFirestore.instance),
       _identity = identity ?? LocalPrinterDeviceIdentity();

  final PrintJobRepository _queue;
  final PrinterDeviceRepository _devices;
  final LocalPrinterDeviceIdentity _identity;
  DateTime? _lastHeartbeatAt;

  Future<PrintWorkerResult> processNext(VenueScope scope) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return PrintWorkerResult.noWork;
    final deviceId = await _identity.getOrCreate();
    final device = await _devices.getDevice(
      tenantId: scope.tenantId,
      deviceId: deviceId,
    );
    if (device == null ||
        !device.active ||
        device.venueId != scope.venueId ||
        device.assignedUserId != user.uid ||
        !device.transports.contains('bluetooth')) {
      return PrintWorkerResult.noWork;
    }

    final now = DateTime.now();
    if (_lastHeartbeatAt == null ||
        now.difference(_lastHeartbeatAt!) >= const Duration(seconds: 30)) {
      await _devices.heartbeat(tenantId: scope.tenantId, deviceId: deviceId);
      _lastHeartbeatAt = now;
    }
    final worker = NativePrintWorker(
      queue: _queue,
      printer: QueuedBluetoothReceiptPrinter(),
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      deviceId: deviceId,
    );
    try {
      return await worker.processNext();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Process queued Bluetooth print job', error, stackTrace);
      return PrintWorkerResult.failed;
    }
  }
}
