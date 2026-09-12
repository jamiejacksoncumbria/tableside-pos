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

/// Uploads the durable outbox in sequence order. Network and server outages
/// leave events pending. Only an explicit permanent rejection quarantines an
/// event; ambiguous responses are always safe to retry by immutable event ID.
class VenueHubCloudSync {
  VenueHubCloudSync({
    required VenueHubCloudUploader upload,
    OfflineEventLedger? ledger,
    this.batchSize = 25,
    this.retryDelay = const Duration(seconds: 10),
  }) : _upload = upload,
       _ledger = ledger ?? OfflineEventLedger.instance;

  final VenueHubCloudUploader _upload;
  final OfflineEventLedger _ledger;
  final int batchSize;
  final Duration retryDelay;
  Timer? _retryTimer;
  bool _flushing = false;
  bool _disposed = false;

  Future<int> flush() async {
    if (_disposed || _flushing) return 0;
    _flushing = true;
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
          AppLogger.error('Synchronise venue hub outbox', error, stackTrace);
          _scheduleRetry();
          break;
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
    }
    return synced;
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer?.isActive == true) return;
    _retryTimer = Timer(retryDelay, flush);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
  }
}
