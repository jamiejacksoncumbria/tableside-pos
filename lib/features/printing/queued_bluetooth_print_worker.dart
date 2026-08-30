import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import '../../data/printer_device_repository.dart';
import 'local_printer_device_identity.dart';
import 'native_print_worker.dart';
import 'queued_bluetooth_receipt_printer.dart';
import 'queued_windows_receipt_printer.dart';

/// Runs only in a foreground native app session. Android boot/background
/// services are a later device-agent step; this worker gives each registered
/// Android or Windows device reliable foreground queue processing now.
class QueuedNativePrintWorker {
  QueuedNativePrintWorker({
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

  String? get _requiredTransport => Platform.isWindows
      ? 'windowsPrintQueue'
      : Platform.isAndroid
      ? 'bluetooth'
      : null;

  /// Signals that a venue has queued work. The host listens to this stream and
  /// claims jobs immediately; it does not wait for a periodic scan.
  Stream<int> watchQueuedJobCount(VenueScope scope) => _queue
      .watchQueuedJobCount(tenantId: scope.tenantId, venueId: scope.venueId);

  /// Keeps a registered foreground printer visible to the venue-wide delivery
  /// monitor even while it has no jobs. An unregistered till performs no
  /// heartbeat write, so this is safe to call on the shared app shell timer.
  Future<void> maintainHeartbeat(VenueScope scope) async {
    final now = DateTime.now();
    if (_lastHeartbeatAt != null &&
        now.difference(_lastHeartbeatAt!) < const Duration(seconds: 30)) {
      return;
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      final requiredTransport = _requiredTransport;
      if (user == null || requiredTransport == null) return;
      var deviceId = await _identity.deviceIdForScope(scope);
      var deviceCredential = await _identity.credential(scope);
      if (deviceCredential == null || deviceCredential.isEmpty) {
        final legacyCredential = await _identity.legacyCredential();
        if (legacyCredential != null && legacyCredential.isNotEmpty) {
          deviceId = await _identity.getOrCreate();
          deviceCredential = legacyCredential;
        }
      }
      if (deviceCredential == null || deviceCredential.isEmpty) return;
      final device = await _devices.getDevice(
        tenantId: scope.tenantId,
        deviceId: deviceId,
      );
      if (device == null ||
          !device.active ||
          device.venueId != scope.venueId ||
          !device.transports.contains(requiredTransport)) {
        return;
      }
      await _devices.heartbeat(
        scope: scope,
        deviceId: deviceId,
        deviceCredential: deviceCredential,
      );
      _lastHeartbeatAt = now;
    } on Object catch (error, stackTrace) {
      AppLogger.error('Maintain printer device heartbeat', error, stackTrace);
    }
  }

  Future<PrintWorkerResult> processNext(VenueScope scope) async {
    final user = FirebaseAuth.instance.currentUser;
    final requiredTransport = _requiredTransport;
    if (user == null || requiredTransport == null) {
      return PrintWorkerResult.noWork;
    }
    var deviceId = await _identity.deviceIdForScope(scope);
    var deviceCredential = await _identity.credential(scope);
    if (deviceCredential == null || deviceCredential.isEmpty) {
      final legacyCredential = await _identity.legacyCredential();
      if (legacyCredential != null && legacyCredential.isNotEmpty) {
        deviceId = await _identity.getOrCreate();
        deviceCredential = legacyCredential;
      }
    }
    if (deviceCredential == null || deviceCredential.isEmpty) {
      return PrintWorkerResult.noWork;
    }
    final device = await _devices.getDevice(
      tenantId: scope.tenantId,
      deviceId: deviceId,
    );
    if (device == null ||
        !device.active ||
        device.venueId != scope.venueId ||
        !device.transports.contains(requiredTransport)) {
      return PrintWorkerResult.noWork;
    }

    final now = DateTime.now();
    if (_lastHeartbeatAt == null ||
        now.difference(_lastHeartbeatAt!) >= const Duration(seconds: 30)) {
      await _devices.heartbeat(
        scope: scope,
        deviceId: deviceId,
        deviceCredential: deviceCredential,
      );
      _lastHeartbeatAt = now;
    }
    final worker = NativePrintWorker(
      queue: _queue,
      printer: Platform.isWindows
          ? QueuedWindowsReceiptPrinter()
          : QueuedBluetoothReceiptPrinter(),
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      deviceId: deviceId,
      deviceCredential: deviceCredential,
    );
    try {
      return await worker.processNext();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Process queued native print job', error, stackTrace);
      return PrintWorkerResult.failed;
    }
  }
}

/// Retained for hot-reload compatibility with older running sessions. New code
/// uses [QueuedNativePrintWorker], but keeping the previous class name lets a
/// pre-upgrade State object complete its timer callback until the required
/// full Windows restart installs the native printer channel.
@Deprecated('Use QueuedNativePrintWorker instead.')
class QueuedBluetoothPrintWorker extends QueuedNativePrintWorker {
  QueuedBluetoothPrintWorker({super.queue, super.devices, super.identity});
}
