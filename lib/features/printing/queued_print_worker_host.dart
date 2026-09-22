import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../offline/venue_hub_runtime.dart';
import '../notifications/notification_centre.dart';
import 'native_print_worker.dart';
import 'queued_bluetooth_print_worker.dart';

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
  StreamSubscription<int>? _queuedJobsSubscription;
  StreamSubscription<VenueHubRuntimeStatus>? _hubStatusSubscription;
  VenueScope? _scope;
  bool _watchingLocalHubQueue = false;
  bool _processing = false;

  @override
  void dispose() {
    _retryTimer?.cancel();
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
    _queuedJobsSubscription?.cancel();
    _hubStatusSubscription?.cancel();
    _scope = scope;
    _watchingLocalHubQueue = false;
    if (scope == null || Firebase.apps.isEmpty) return;
    final worker = _worker ??= QueuedNativePrintWorker();
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
    _retryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(worker.maintainHeartbeat(scope));
      // The timer is a safety net for a platform stream interruption. Normal
      // jobs wake the worker immediately through the queue subscription.
      unawaited(_processAvailable(scope));
    });
    unawaited(worker.maintainHeartbeat(scope));
    unawaited(_processAvailable(scope));
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

  Future<void> _processAvailable(VenueScope scope) async {
    if (_processing || !mounted || _scope != scope) return;
    final worker = _worker;
    if (worker == null) return;
    _processing = true;
    try {
      while (mounted && _scope == scope) {
        final result = await worker.processNext(scope);
        if (!mounted || _scope != scope) return;
        if (result == PrintWorkerResult.noWork) return;
        if (result == PrintWorkerResult.printed) {
          AppLogger.info('Queued native printer: ticket printed.');
          continue;
        }
        AppLogger.error(
          'Queued native printer',
          StateError('A queued ticket failed and will be retried or flagged.'),
          StackTrace.current,
        );
        showAppNotification(
          context,
          ref: ref,
          title: 'Printer job needs attention',
          message:
              'A queued ticket or paid receipt could not print. It will retry automatically.',
          level: AppNotificationLevel.error,
        );
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
}
