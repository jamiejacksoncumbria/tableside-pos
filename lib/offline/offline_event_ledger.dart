import '../core/app_logger.dart';
import 'offline_event.dart';
import 'offline_event_store_base.dart';
import 'offline_event_store_factory.dart';

class OfflineEventLedger {
  OfflineEventLedger._({OfflineEventStore? store})
    : _store = store ?? createOfflineEventStore();

  static final OfflineEventLedger instance = OfflineEventLedger._();

  final OfflineEventStore _store;
  bool _ready = false;
  Object? _initializationError;

  bool get isSupported => _store.isSupported;
  bool get isReady => _ready;
  Object? get initializationError => _initializationError;

  Future<void> initialize() async {
    if (_ready || !_store.isSupported) return;
    try {
      await _store.initialize();
      _ready = true;
      _initializationError = null;
      AppLogger.info(
        'Durable offline event ledger ready (encrypted SQLite, WAL, synchronous FULL).',
      );
    } catch (error, stackTrace) {
      _initializationError = error;
      AppLogger.error(
        'Initialize durable offline event ledger',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<OfflineEvent> commit(
    OfflineEventDraft draft, {
    required int hubEpoch,
  }) async {
    _requireReady();
    final event = await _store.append(draft, hubEpoch: hubEpoch);
    AppLogger.info(
      'Offline event committed: type=${event.type}, sequence=${event.sequence}, state=pending.',
    );
    return event;
  }

  Future<List<OfflineEvent>> pending({int limit = 250}) {
    _requireReady();
    return _store.pending(limit: limit);
  }

  Future<List<OfflineEvent>> eventsForVenue({
    required String tenantId,
    required String venueId,
    required int hubEpoch,
    int limit = 10000,
  }) {
    _requireReady();
    return _store.eventsForVenue(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
      limit: limit,
    );
  }

  Stream<List<OfflineEvent>> watchPending({int limit = 250}) {
    _requireReady();
    return _store.watchPending(limit: limit);
  }

  Future<void> saveSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
    required int version,
    required Map<String, Object?> value,
  }) {
    _requireReady();
    return _store.saveSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: kind,
      version: version,
      value: value,
    );
  }

  Future<Map<String, Object?>?> readSnapshot({
    required String tenantId,
    required String venueId,
    required String kind,
  }) {
    _requireReady();
    return _store.readSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: kind,
    );
  }

  Future<void> markInFlight(String eventId) {
    _requireReady();
    return _store.markInFlight(eventId);
  }

  Future<void> markPending(String eventId) {
    _requireReady();
    return _store.markPending(eventId);
  }

  Future<void> markSynced(String eventId, DateTime acknowledgedAtUtc) {
    _requireReady();
    return _store.markSynced(eventId, acknowledgedAtUtc);
  }

  Future<void> quarantine(String eventId, String reason) {
    _requireReady();
    return _store.quarantine(eventId, reason);
  }

  void _requireReady() {
    if (!_store.isSupported) {
      throw StateError(
        'Durable offline storage is unavailable on this platform.',
      );
    }
    if (!_ready) {
      throw StateError(
        'Durable offline storage is not ready. No operation was accepted.',
      );
    }
  }
}
