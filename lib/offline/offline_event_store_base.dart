import 'offline_event.dart';

abstract interface class OfflineEventStore {
  bool get isSupported;

  Future<void> initialize();

  Future<OfflineEvent> append(OfflineEventDraft draft, {required int hubEpoch});

  Future<List<OfflineEvent>> pending({int limit = 250});

  Stream<List<OfflineEvent>> watchPending({int limit = 250});

  Future<void> saveSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
    required int version,
    required Map<String, Object?> value,
  });

  Future<Map<String, Object?>?> readSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
  });

  Future<void> markInFlight(String eventId);

  Future<void> markSynced(String eventId, DateTime acknowledgedAtUtc);

  Future<void> quarantine(String eventId, String reason);

  Future<void> close();
}
