import 'offline_event.dart';
import 'offline_event_store_base.dart';

OfflineEventStore createOfflineEventStore() => _UnsupportedOfflineEventStore();

class _UnsupportedOfflineEventStore implements OfflineEventStore {
  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<OfflineEvent> append(
    OfflineEventDraft draft, {
    required int hubEpoch,
  }) => throw UnsupportedError(
    'Durable venue-offline storage is currently supported on native devices.',
  );

  @override
  Future<List<OfflineEvent>> pending({int limit = 250}) async => const [];

  @override
  Stream<List<OfflineEvent>> watchPending({int limit = 250}) =>
      Stream.value(const []);

  @override
  Future<void> saveSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
    required int version,
    required Map<String, Object?> value,
  }) => throw UnsupportedError(
    'Durable venue-offline storage is currently supported on native devices.',
  );

  @override
  Future<Map<String, Object?>?> readSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
  }) async => null;

  @override
  Future<void> markInFlight(String eventId) async {}

  @override
  Future<void> markSynced(String eventId, DateTime acknowledgedAtUtc) async {}

  @override
  Future<void> quarantine(String eventId, String reason) async {}

  @override
  Future<void> close() async {}
}
