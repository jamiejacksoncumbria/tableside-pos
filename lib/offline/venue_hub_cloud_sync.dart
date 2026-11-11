import 'dart:async';

import '../core/app_logger.dart';
import 'offline_event.dart';
import 'offline_event_ledger.dart';

class VenueHubCloudUploadResult {
  const VenueHubCloudUploadResult({
    required this.acknowledgedEventIds,
    this.permanentRejections = const <String, String>{},
  });

  final Set<String> acknowledgedEventIds;
  final Map<String, String> permanentRejections;
}

typedef VenueHubCloudUploader =
    Future<VenueHubCloudUploadResult> Function(List<OfflineEvent> events);
typedef VenueHubCloudSyncFailureCallback =
    void Function(Object error, int consecutiveFailures);
typedef VenueHubCloudSyncRecoveredCallback = void Function();

/// Uploads the durable outbox in sequence order. Network and server outages
/// leave events pending. Only an explicit permanent rejection quarantines an
/// event; ambiguous responses are always safe to retry by immutable event ID.
class VenueHubCloudSync {
  VenueHubCloudSync({
    required VenueHubCloudUploader upload,
    OfflineEventLedger? ledger,
    this.batchSize = 25,
    this.retryDelay = const Duration(seconds: 10),
    this.maximumRetryDelay = const Duration(minutes: 5),
    this.onFailure,
    this.onRecovered,
  }) : _upload = upload,
       _ledger = ledger ?? OfflineEventLedger.instance;

  final VenueHubCloudUploader _upload;
  final OfflineEventLedger _ledger;
  final int batchSize;
  final Duration retryDelay;
  final Duration maximumRetryDelay;
  final VenueHubCloudSyncFailureCallback? onFailure;
  final VenueHubCloudSyncRecoveredCallback? onRecovered;
  Timer? _retryTimer;
  bool _flushing = false;
  bool _flushRequested = false;
  bool _disposed = false;
  int _consecutiveFailures = 0;

  Future<int> flush() async {
    if (_disposed) return 0;
    if (_flushing) {
      // Do not lose a wake-up when an event is committed after the active
      // upload read its batch. The current flush cannot see that event, so it
      // must run once more as soon as it releases the serial upload lock.
      _flushRequested = true;
      return 0;
    }
    if (_retryTimer?.isActive == true) return 0;
    _flushing = true;
    _flushRequested = false;
    var synced = 0;
    try {
      while (!_disposed) {
        final pending = await _ledger.pending(limit: batchSize);
        if (pending.isEmpty) break;
        for (final event in pending) {
          await _ledger.markInFlight(event.id);
        }
        VenueHubCloudUploadResult result;
        try {
          result = await _upload(pending);
        } catch (error, stackTrace) {
          for (final event in pending) {
            await _ledger.markPending(event.id);
          }
          _consecutiveFailures++;
          onFailure?.call(error, _consecutiveFailures);
          if (_consecutiveFailures == 1) {
            if (error.toString().contains('synchronization conflict')) {
              AppLogger.error(
                'Venue hub cloud synchronization conflict; pending events '
                'remain safely stored and were not discarded',
                error,
                stackTrace,
              );
            } else {
              AppLogger.error(
                'Synchronize venue hub events; cloud may be temporarily '
                'unavailable and pending events remain safely stored',
                error,
                stackTrace,
              );
            }
          }
          _scheduleRetry();
          break;
        }
        if (_consecutiveFailures > 0) {
          AppLogger.info(
            'Venue hub cloud connection restored; synchronising pending events.',
          );
          _consecutiveFailures = 0;
          onRecovered?.call();
        }
        final now = DateTime.now().toUtc();
        for (final event in pending) {
          final rejection = result.permanentRejections[event.id];
          if (rejection != null) {
            await _ledger.quarantine(event.id, rejection);
          } else if (result.acknowledgedEventIds.contains(event.id)) {
            await _ledger.markSynced(event.id, now);
            synced++;
          } else {
            // The outcome is unknown, so make it retryable immediately. The
            // immutable event ID makes a duplicate upload idempotent.
            for (final retryEvent in pending) {
              if (!result.acknowledgedEventIds.contains(retryEvent.id) &&
                  !result.permanentRejections.containsKey(retryEvent.id)) {
                await _ledger.markPending(retryEvent.id);
              }
            }
            _scheduleRetry();
            return synced;
          }
        }
        if (pending.length < batchSize) break;
      }
    } finally {
      _flushing = false;
      if (_flushRequested && !_disposed && _retryTimer?.isActive != true) {
        _flushRequested = false;
        unawaited(flush());
      }
    }
    return synced;
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer?.isActive == true) return;
    final exponent = (_consecutiveFailures - 1).clamp(0, 8).toInt();
    final proposedMilliseconds = retryDelay.inMilliseconds * (1 << exponent);
    final delay = Duration(
      milliseconds: proposedMilliseconds
          .clamp(retryDelay.inMilliseconds, maximumRetryDelay.inMilliseconds)
          .toInt(),
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(flush());
    });
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
  }
}
