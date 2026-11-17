import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/safe_dialog.dart';
import '../../core/tenant_scope.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_platform.dart';
import '../../offline/venue_hub_runtime.dart';
import '../notifications/notification_centre.dart';
import 'bluetooth_receipt_printer_factory.dart';
import 'native_print_worker.dart';
import 'queued_native_print_worker.dart';

/// Keeps an enrolled native printer device alive for the selected venue even
/// while the staff workspace is PIN-locked.
///
/// Claiming and completing jobs use the enrolled device credential. A staff
/// PIN remains mandatory for order/payment mutations, but must never be a
/// dependency of unattended print delivery.
class QueuedPrintWorkerHost extends ConsumerStatefulWidget {
  const QueuedPrintWorkerHost({super.key});

  @override
  ConsumerState<QueuedPrintWorkerHost> createState() =>
      _QueuedPrintWorkerHostState();
}

class _QueuedPrintWorkerHostState extends ConsumerState<QueuedPrintWorkerHost> {
  QueuedNativePrintWorker? _worker;
  Timer? _retryTimer;
  Timer? _lanQueueTimer;
  Timer? _printFailureRetryTimer;
  StreamSubscription<int>? _queuedJobsSubscription;
  StreamSubscription<VenueHubRuntimeStatus>? _hubStatusSubscription;
  VenueScope? _scope;
  bool _watchingLocalHubQueue = false;
  bool _processing = false;
  bool _printerFailureActive = false;
  bool _printerFailureDialogVisible = false;

  @override
  void dispose() {
    _retryTimer?.cancel();
    _lanQueueTimer?.cancel();
    _printFailureRetryTimer?.cancel();
    _queuedJobsSubscription?.cancel();
    _hubStatusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope != _scope) scheduleMicrotask(() => _configure(scope));
    return const SizedBox.shrink();
  }

  void _configure(VenueScope? scope) {
    if (!mounted || scope == _scope) return;
    _retryTimer?.cancel();
    _lanQueueTimer?.cancel();
    _printFailureRetryTimer?.cancel();
    _queuedJobsSubscription?.cancel();
    _hubStatusSubscription?.cancel();
    _scope = scope;
    _watchingLocalHubQueue = false;
    _printerFailureActive = false;
    _printerFailureDialogVisible = false;
    if (scope == null) return;
    unawaited(_restoreAndroidPrinterService());
    final worker = _worker ??= QueuedNativePrintWorker.instance;
    _subscribeToQueue(worker, scope);
    // The print worker is mounted before the asynchronous venue hub startup
    // completes. Rebind as soon as the encrypted hub queue becomes ready;
    // otherwise the worker remains attached only to the legacy Firestore
    // queue and misses the immediate wake-up for local production tickets.
    _hubStatusSubscription = VenueHubRuntime.instance.statuses.listen((status) {
      if (!mounted || _scope != scope) return;
      final localReady =
          VenueHubRuntime.instance.activeScope == scope &&
          (status.state == VenueHubRuntimeState.ready ||
              status.state == VenueHubRuntimeState.degraded);
      if (localReady != _watchingLocalHubQueue) {
        _watchingLocalHubQueue = localReady;
        _subscribeToQueue(worker, scope);
        if (localReady) {
          AppLogger.info(
            'Printer worker attached to the ready encrypted venue-hub queue.',
          );
          unawaited(_processAvailable(scope));
        }
      }
    });
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(worker.maintainHeartbeat(scope));
      // Queue streams and the RTDB printer signal wake real jobs. Do not issue
      // an empty Cloud Function claim on a timer: fifty venues would otherwise
      // create thousands of unnecessary invocations every day.
    });
    // EPOS 3 production jobs live in the encrypted hub queue. A printer on a
    // separate Android terminal receives no Firebase signal for that local
    // write, so use a fast certificate-pinned LAN check. localHubOnly keeps
    // an empty or unavailable LAN queue from falling through to a billable
    // Cloud Function claim. The authoritative hub process already receives
    // immediate queue-stream events and does not need to poll itself.
    _lanQueueTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final printerRegistry = VenueHubPrinterClientRegistry.instance;
      if (printerRegistry.requiresHub(scope) &&
          printerRegistry.isDeviceEnrolled(scope) &&
          !printerRegistry.isLocalHubHost(scope)) {
        unawaited(_processAvailable(scope, localHubOnly: true));
      }
    });
    AppLogger.info(
      'Printer worker will check the venue hub LAN queue every 2 seconds '
      'without using Firebase claims.',
    );
    unawaited(worker.maintainHeartbeat(scope));
    unawaited(_processAvailable(scope));
  }

  Future<void> _restoreAndroidPrinterService() async {
    try {
      final printer = createBluetoothReceiptPrinter();
      if (!printer.isSupported) return;
      final selected = await printer.selectedDevice();
      if (selected == null) {
        await AndroidVenueHubService.stopPrinter();
      } else {
        await AndroidVenueHubService.startPrinter();
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Restore Android printer background service',
        error,
        stackTrace,
      );
    }
  }

  void _subscribeToQueue(QueuedNativePrintWorker worker, VenueScope scope) {
    unawaited(_queuedJobsSubscription?.cancel());
    _queuedJobsSubscription = worker
        .watchQueuedJobCount(scope)
        .listen(
          (queuedCount) {
            AppLogger.info(
              'Queued printer stream: $queuedCount queued job(s) for this venue.',
            );
            if (queuedCount > 0) unawaited(_processAvailable(scope));
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error('Queued printer stream', error, stackTrace);
            if (!mounted) return;
            showAppNotification(
              context,
              ref: ref,
              title: 'Printer queue connection failed',
              message:
                  'Could not watch the printer queue. Check the connection.',
              level: AppNotificationLevel.error,
            );
          },
        );
  }

  Future<void> _processAvailable(
    VenueScope scope, {
    bool localHubOnly = false,
  }) async {
    if (_processing || !mounted || _scope != scope) return;
    final runtime = VenueHubRuntime.instance;
    if (VenueHubPrinterClientRegistry.instance.isLocalHubHost(scope) &&
        runtime.activeScope != scope) {
      // The worker and hub auto-start hosts mount together. The printer
      // registry already knows this device owns the hub before its HTTPS
      // listener has bound. Wait for the runtime status stream to wake this
      // worker instead of recording a false failed ticket/notification.
      return;
    }
    if (VenueHubPrinterClientRegistry.instance.isLocalHubHost(scope) &&
        runtime.status.state != VenueHubRuntimeState.ready &&
        runtime.status.state != VenueHubRuntimeState.degraded) {
      return;
    }
    final worker = _worker;
    if (worker == null) return;
    _processing = true;
    try {
      while (mounted && _scope == scope) {
        final result = await worker.processNext(
          scope,
          localHubOnly: localHubOnly,
        );
        if (!mounted || _scope != scope) return;
        if (result == PrintWorkerResult.noWork) return;
        if (result == PrintWorkerResult.printed) {
          AppLogger.info('Queued native printer: ticket printed.');
          _resolvePrinterFailure(scope);
          continue;
        }
        AppLogger.error(
          'Queued native printer',
          StateError('A queued ticket failed and will be retried or flagged.'),
          StackTrace.current,
        );
        _reportPrinterFailure(scope, worker.lastPrinterFailure);
        // Completing a failed physical attempt puts the same durable job back
        // into `queued`. Its stream notification can arrive while this method
        // still owns `_processing`, so that wake-up is intentionally ignored.
        // Schedule a fresh LAN-only pass after this call has unwound. This is
        // what advances an unavailable printer through all three attempts and
        // makes the job visibly `failed` in recovery instead of stranding it.
        _printFailureRetryTimer?.cancel();
        _printFailureRetryTimer = Timer(const Duration(seconds: 5), () {
          if (mounted && _scope == scope) {
            unawaited(_processAvailable(scope, localHubOnly: true));
          }
        });
        return;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Queued native print worker', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Printer worker failed',
          message: 'The printer worker encountered an error and will retry.',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      _processing = false;
    }
  }

  String _printerFailureKey(VenueScope scope) =>
      'local-printer-failure-${scope.tenantId}-${scope.venueId}';

  void _resolvePrinterFailure(VenueScope scope) {
    if (!_printerFailureActive || !mounted || _scope != scope) return;
    _printerFailureActive = false;
    ref
        .read(appNotificationsProvider.notifier)
        .resolve(_printerFailureKey(scope));
  }

  void _reportPrinterFailure(VenueScope scope, String? technicalReason) {
    if (!mounted || _scope != scope) return;
    final reason = technicalReason?.trim();
    final message = [
      'This device could not print a queued ticket or receipt.',
      'Make sure the printer is connected, has paper and is powered on. '
          'If it was already on, switch it off, wait a few seconds and power it on again. '
          'The ticket will retry automatically.',
      if (reason != null && reason.isNotEmpty) 'Reported problem: $reason',
    ].join('\n\n');
    showAppNotification(
      context,
      ref: ref,
      title: 'Printer connected to this device needs attention',
      message: message,
      level: AppNotificationLevel.error,
      deduplicationKey: _printerFailureKey(scope),
      requiresAttention: true,
    );
    if (_printerFailureActive || _printerFailureDialogVisible) return;
    _printerFailureActive = true;
    unawaited(_showPrinterFailureDialog(scope, message));
  }

  Future<void> _showPrinterFailureDialog(
    VenueScope scope,
    String message,
  ) async {
    if (!mounted || _scope != scope || _printerFailureDialogVisible) return;
    _printerFailureDialogVisible = true;
    try {
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.print_disabled_rounded),
          title: const Text('Printer is not responding'),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Dismiss and keep working'),
            ),
          ],
        ),
      );
    } finally {
      _printerFailureDialogVisible = false;
    }
  }
}
