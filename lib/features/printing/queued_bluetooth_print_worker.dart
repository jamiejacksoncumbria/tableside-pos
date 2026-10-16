import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import '../../data/printer_device_repository.dart';
import 'local_printer_device_identity.dart';
import 'native_print_worker.dart';
import 'queued_bluetooth_receipt_printer.dart';
import 'queued_windows_receipt_printer.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_runtime.dart';

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
  DateTime? _heartbeatRetryAfter;
  VenueScope? _heartbeatScope;
  bool _cloudHeartbeatOffline = false;
  String? _lastReadinessDiagnostic;

  String? get _requiredTransport {
    // `Platform` from dart:io throws at runtime in a browser. Web is a POS
    // client only: it queues jobs for registered Android/Windows agents and
    // must never try to heartbeat or claim a native print job itself.
    if (kIsWeb) return null;
    return Platform.isWindows
        ? 'windowsPrintQueue'
        : Platform.isAndroid
        ? 'bluetooth'
        : null;
  }

  /// Signals that a venue has queued work. The host listens to this stream and
  /// claims jobs immediately; it does not wait for a periodic scan.
  Stream<int> watchQueuedJobCount(VenueScope scope) => _queue
      .watchQueuedJobCount(tenantId: scope.tenantId, venueId: scope.venueId);

  /// Keeps a registered foreground printer visible to the venue-wide delivery
  /// monitor even while it has no jobs. An unregistered till performs no
  /// heartbeat write, so this is safe to call on the shared app shell timer.
  Future<void> maintainHeartbeat(VenueScope scope) async {
    final now = DateTime.now();
    if (_heartbeatRetryAfter?.isAfter(now) == true) return;
    if (_heartbeatScope == scope &&
        _lastHeartbeatAt != null &&
        now.difference(_lastHeartbeatAt!) < const Duration(seconds: 60)) {
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
      // Hub-local tickets are claimed without Firebase, but the cloud device
      // heartbeat still feeds every till's delivery monitor. Suppressing this
      // heartbeat in hub mode made a healthy local printer appear offline and
      // obscured the real state of queued tickets.
      await _devices.heartbeat(
        scope: scope,
        deviceId: deviceId,
        deviceCredential: deviceCredential,
      );
      _lastHeartbeatAt = now;
      _heartbeatScope = scope;
      _heartbeatRetryAfter = null;
      if (_cloudHeartbeatOffline) {
        AppLogger.info('Printer device cloud heartbeat restored.');
        _cloudHeartbeatOffline = false;
      }
    } on Object catch (error) {
      // Internet loss is an expected operating mode for a venue hub. Back off
      // cloud-only presence updates while the encrypted LAN queue continues;
      // otherwise a ten-second timer floods the diagnostics with identical
      // socket stacks and can contend with local printing.
      _heartbeatRetryAfter = now.add(const Duration(minutes: 2));
      if (!_cloudHeartbeatOffline) {
        AppLogger.info(
          'Printer cloud heartbeat is offline; local hub printing remains active. ($error)',
        );
        _cloudHeartbeatOffline = true;
      }
    }
  }

  Future<PrintWorkerResult> processNext(VenueScope scope) async {
    final user = FirebaseAuth.instance.currentUser;
    final requiredTransport = _requiredTransport;
    if (user == null) return _notReady('Firebase host account is signed out.');
    if (requiredTransport == null) {
      return _notReady('This platform cannot run a native printer worker.');
    }
    var deviceId = await _identity.deviceIdForScope(scope);
    var deviceCredential = await _identity.credential(scope);
    // The host itself owns the durable local queue even when its separate
    // printer-only registry has not yet completed a LAN client handshake.
    // Treating it as a cloud printer made queued local tickets wait forever
    // despite a healthy configured printer and successful test prints.
    final hubMode =
        VenueHubRuntime.instance.activeScope == scope ||
        VenueHubPrinterClientRegistry.instance.requiresHub(scope);
    if (deviceCredential == null || deviceCredential.isEmpty) {
      final legacyCredential = await _identity.legacyCredential();
      if (legacyCredential != null && legacyCredential.isNotEmpty) {
        deviceId = await _identity.getOrCreate();
        deviceCredential = legacyCredential;
      }
    }
    if ((deviceCredential == null || deviceCredential.isEmpty) && !hubMode) {
      return _notReady(
        'No venue-scoped printer credential is stored for device $deviceId.',
      );
    }
    if (deviceId.isEmpty) {
      return _notReady('The local printer device ID is empty.');
    }
    if (hubMode && (deviceCredential == null || deviceCredential.isEmpty)) {
      // Local encrypted jobs do not need a bearer credential. Keep a marker
      // only when no real credential exists; a real credential is required to
      // drain legacy/server-created cloud jobs after the local queue is empty.
      deviceCredential = 'venue-hub-device-credential';
    } else {
      final device = await _devices.getDevice(
        tenantId: scope.tenantId,
        deviceId: deviceId,
      );
      if (device == null ||
          !device.active ||
          device.venueId != scope.venueId ||
          !device.transports.contains(requiredTransport)) {
        return _notReady(
          'Printer registration is missing, inactive, assigned to another venue, or lacks transport $requiredTransport. device=$deviceId.',
        );
      }
    }

    final readyDiagnostic =
        'Printer worker ready: device=$deviceId, transport=$requiredTransport, hubMode=$hubMode.';
    if (_lastReadinessDiagnostic != readyDiagnostic) {
      AppLogger.info(readyDiagnostic);
      _lastReadinessDiagnostic = readyDiagnostic;
    }

    final now = DateTime.now();
    if (!hubMode &&
        (_heartbeatScope != scope ||
            _lastHeartbeatAt == null ||
            now.difference(_lastHeartbeatAt!) >= const Duration(seconds: 60))) {
      await _devices.heartbeat(
        scope: scope,
        deviceId: deviceId,
        deviceCredential: deviceCredential!,
      );
      _lastHeartbeatAt = now;
      _heartbeatScope = scope;
    }
    final worker = NativePrintWorker(
      queue: _queue,
      printer: Platform.isWindows
          ? QueuedWindowsReceiptPrinter()
          : QueuedBluetoothReceiptPrinter(),
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      deviceId: deviceId,
      deviceCredential: deviceCredential!,
    );
    try {
      return await worker.processNext();
    } on Object catch (error, stackTrace) {
      if (error is ClientException || error is SocketException) {
        // A cloud claim can be committed immediately before its HTTP response
        // is interrupted. The server lets this same enrolled device resume
        // that claim on the next pass, so this is a temporary transport pause,
        // not evidence that a physical printer or ticket failed.
        AppLogger.info(
          'Printer cloud queue temporarily unavailable; the claim will resume automatically. ($error)',
        );
        return PrintWorkerResult.noWork;
      }
      AppLogger.error('Process queued native print job', error, stackTrace);
      return PrintWorkerResult.failed;
    }
  }

  PrintWorkerResult _notReady(String reason) {
    final diagnostic = 'Printer worker idle: $reason';
    if (_lastReadinessDiagnostic != diagnostic) {
      AppLogger.info(diagnostic);
      _lastReadinessDiagnostic = diagnostic;
    }
    return PrintWorkerResult.noWork;
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
