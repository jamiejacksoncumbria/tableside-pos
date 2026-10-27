import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import 'local_printer_device_identity.dart';
import 'native_print_worker.dart';
import 'printer_realtime_presence.dart';
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
    LocalPrinterDeviceIdentity? identity,
  }) : _queue =
           queue ??
           (Firebase.apps.isEmpty
               ? PrintJobRepository.localOnly()
               : PrintJobRepository(FirebaseFirestore.instance)),
       _identity = identity ?? LocalPrinterDeviceIdentity();

  final PrintJobRepository _queue;
  final LocalPrinterDeviceIdentity _identity;
  final PrinterRealtimePresence _realtime = PrinterRealtimePresence();
  String? _lastReadinessDiagnostic;
  final Set<String> _printedAwaitingCompletion = <String>{};

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
  Stream<int> watchQueuedJobCount(VenueScope scope) {
    return Stream<int>.multi((controller) {
      // The encrypted venue-hub queue is inspected by processNext. Cloud jobs
      // wake this worker through RTDB and are then claimed atomically through
      // the device-credential API. This deliberately avoids a Firestore read
      // before a member has entered a PIN.
      controller.add(0);
      final localQueue = VenueHubRuntime.instance.localPrintJobs(scope);
      final localSubscription = localQueue?.listen(
        (jobs) => controller.add(
          jobs.where((job) => job['status'] == 'queued').length,
        ),
        onError: controller.addError,
      );
      final signalSubscription = _realtime.signals.listen((_) {
        controller.add(1);
      }, onError: controller.addError);
      controller.onCancel = () async {
        await localSubscription?.cancel();
        await signalSubscription.cancel();
      };
    });
  }

  /// Keeps a registered foreground printer visible to the venue-wide delivery
  /// monitor even while it has no jobs. An unregistered till performs no
  /// heartbeat write, so this is safe to call on the shared app shell timer.
  Future<void> maintainHeartbeat(VenueScope scope) async {
    try {
      if (Firebase.apps.isEmpty) return;
      final user = FirebaseAuth.instance.currentUser;
      final requiredTransport = _requiredTransport;
      if (user == null || requiredTransport == null) return;
      final deviceId = await _identity.deviceIdForScope(scope);
      final deviceCredential = await _identity.credential(scope);
      if (deviceCredential == null || deviceCredential.isEmpty) return;
      if (_realtime.isConfigured(scope, deviceId)) return;
      // issueRealtimePrinterSession validates the credential, venue,
      // enrollment, active state and transport on the trusted server.
      await _realtime.start(
        scope: scope,
        deviceId: deviceId,
        deviceCredential: deviceCredential,
      );
    } on Object catch (error) {
      AppLogger.info(
        'Printer realtime presence is offline; local hub printing remains active. ($error)',
      );
    }
  }

  Future<PrintWorkerResult> processNext(VenueScope scope) async {
    final requiredTransport = _requiredTransport;
    if (requiredTransport == null) {
      return _notReady('This platform cannot run a native printer worker.');
    }
    final deviceId = await _identity.deviceIdForScope(scope);
    var deviceCredential = await _identity.credential(scope);
    // The host itself owns the durable local queue even when its separate
    // printer-only registry has not yet completed a LAN client handshake.
    // Treating it as a cloud printer made queued local tickets wait forever
    // despite a healthy configured printer and successful test prints.
    final hubMode =
        VenueHubRuntime.instance.activeScope == scope ||
        VenueHubPrinterClientRegistry.instance.requiresHub(scope);
    // A local venue hub is authenticated by its encrypted device enrolment and
    // can keep printing through an internet outage. Only a cloud-only printer
    // worker requires a live Firebase host account.
    if (!hubMode &&
        (Firebase.apps.isEmpty || FirebaseAuth.instance.currentUser == null)) {
      return _notReady('Firebase host account is signed out.');
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
      // only when no real venue-scoped credential exists.
      deviceCredential = 'venue-hub-device-credential';
    }

    final readyDiagnostic =
        'Printer worker ready: device=$deviceId, transport=$requiredTransport, hubMode=$hubMode.';
    if (_lastReadinessDiagnostic != readyDiagnostic) {
      AppLogger.info(readyDiagnostic);
      _lastReadinessDiagnostic = readyDiagnostic;
    }

    if (!hubMode && !_realtime.isConfigured(scope, deviceId)) {
      await maintainHeartbeat(scope);
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
      printedAwaitingCompletion: _printedAwaitingCompletion,
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
