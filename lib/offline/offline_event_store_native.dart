import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'offline_event.dart';
import 'offline_event_crypto.dart';
import 'offline_event_store_base.dart';

OfflineEventStore createOfflineEventStore() => NativeOfflineEventStore();

class NativeOfflineEventStore implements OfflineEventStore {
  NativeOfflineEventStore({OfflineEventCrypto? crypto, this._database})
    : _crypto = crypto ?? OfflineEventCrypto();

  static const _schemaVersion = 1;
  static const _maximumPayloadBytes = 512 * 1024;

  final OfflineEventCrypto _crypto;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void> _operation = Future.value();
  Database? _database;
  bool _initialized = false;
  bool _closed = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() => _serial(_initializeInternal);

  Future<void> _initializeInternal() async {
    if (_closed) throw StateError('The offline event store is closed.');
    if (_initialized) return;
    await _crypto.initialize();
    final database = _database ?? await _openDefaultDatabase();
    try {
      database
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = FULL')
        ..execute('PRAGMA foreign_keys = ON')
        ..execute('PRAGMA secure_delete = ON')
        ..execute('PRAGMA busy_timeout = 5000')
        ..execute('''
          CREATE TABLE IF NOT EXISTS offline_events (
            event_id TEXT PRIMARY KEY NOT NULL,
            venue_key TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK(sequence > 0),
            hub_epoch INTEGER NOT NULL CHECK(hub_epoch > 0),
            created_at_utc_ms INTEGER NOT NULL,
            previous_hash TEXT NOT NULL,
            event_hash TEXT NOT NULL UNIQUE,
            nonce BLOB NOT NULL,
            cipher_text BLOB NOT NULL CHECK(length(cipher_text) <= 1048576),
            mac BLOB NOT NULL,
            sync_state INTEGER NOT NULL DEFAULT 0 CHECK(sync_state BETWEEN 0 AND 3),
            cloud_acknowledged_at_utc_ms INTEGER,
            quarantine_reason TEXT,
            UNIQUE(venue_key, hub_epoch, sequence)
          ) STRICT
        ''')
        ..execute('''
          CREATE INDEX IF NOT EXISTS offline_events_pending
          ON offline_events(sync_state, created_at_utc_ms, sequence)
        ''')
        ..execute('''
          CREATE INDEX IF NOT EXISTS offline_events_venue_sequence
          ON offline_events(venue_key, hub_epoch, sequence)
        ''')
        // An interrupted upload is safe to retry because cloud ingestion uses
        // event_id as its idempotency key.
        ..execute(
          'UPDATE offline_events SET sync_state = 0 WHERE sync_state = 1',
        )
        ..execute('PRAGMA user_version = $_schemaVersion');
      _database = database;
      _initialized = true;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  Future<Database> _openDefaultDatabase() async {
    final support = await getApplicationSupportDirectory();
    final separator = support.path.endsWith('/') || support.path.endsWith('\\')
        ? ''
        : Platform.pathSeparator;
    return sqlite3.open(
      '${support.path}${separator}tableside_offline_events.sqlite3',
    );
  }

  @override
  Future<OfflineEvent> append(
    OfflineEventDraft draft, {
    required int hubEpoch,
  }) => _serial(() async {
    if (hubEpoch < 1) {
      throw ArgumentError.value(hubEpoch, 'hubEpoch', 'Must be positive.');
    }
    await _initializeInternal();
    final database = _database!;
    final venueKey = await _crypto.venueKey(draft.tenantId, draft.venueId);
    final tail = database.select(
      '''
        SELECT sequence, event_hash
        FROM offline_events
        WHERE venue_key = ? AND hub_epoch = ?
        ORDER BY sequence DESC
        LIMIT 1
      ''',
      [venueKey, hubEpoch],
    );
    final sequence = tail.isEmpty ? 1 : (tail.first['sequence'] as int) + 1;
    final previousHash = tail.isEmpty
        ? 'GENESIS:$venueKey:$hubEpoch'
        : tail.first['event_hash'] as String;
    final createdAt = DateTime.now().toUtc();
    final businessTimestamp = (draft.businessTimestamp ?? createdAt).toUtc();
    final eventId = _newEventId(createdAt);
    final associatedData = _associatedData(
      eventId: eventId,
      venueKey: venueKey,
      sequence: sequence,
      hubEpoch: hubEpoch,
      createdAtUtcMs: createdAt.millisecondsSinceEpoch,
      previousHash: previousHash,
    );
    final clearEnvelope = <String, Object?>{
      'schemaVersion': _schemaVersion,
      'tenantId': draft.tenantId,
      'venueId': draft.venueId,
      'deviceId': draft.deviceId,
      'staffId': draft.staffId,
      if (draft.managerApprovalStaffId != null)
        'managerApprovalStaffId': draft.managerApprovalStaffId,
      'type': draft.type,
      'businessTimestampUtc': businessTimestamp.toIso8601String(),
      'payload': draft.payload,
    };
    final clearSize = utf8.encode(jsonEncode(clearEnvelope)).length;
    if (clearSize > _maximumPayloadBytes) {
      throw StateError('The offline operation is too large to store safely.');
    }
    final encrypted = await _crypto.encryptJson(
      clearEnvelope,
      associatedData: associatedData,
    );
    final eventHash = await _crypto.eventHash(
      '$associatedData|${base64UrlEncode(encrypted.nonce)}|'
      '${base64UrlEncode(encrypted.cipherText)}|${base64UrlEncode(encrypted.mac)}',
    );

    database.execute('BEGIN IMMEDIATE');
    try {
      // Recheck the tail inside the durable transaction. All writes in this
      // process are serialized, while the UNIQUE constraint guards accidents.
      final currentTail = database.select(
        '''
          SELECT sequence, event_hash FROM offline_events
          WHERE venue_key = ? AND hub_epoch = ?
          ORDER BY sequence DESC LIMIT 1
        ''',
        [venueKey, hubEpoch],
      );
      final currentSequence = currentTail.isEmpty
          ? 1
          : (currentTail.first['sequence'] as int) + 1;
      final currentPrevious = currentTail.isEmpty
          ? 'GENESIS:$venueKey:$hubEpoch'
          : currentTail.first['event_hash'] as String;
      if (currentSequence != sequence || currentPrevious != previousHash) {
        throw StateError('The local event sequence changed unexpectedly.');
      }
      database.execute(
        '''
          INSERT INTO offline_events (
            event_id, venue_key, sequence, hub_epoch, created_at_utc_ms,
            previous_hash, event_hash, nonce, cipher_text, mac, sync_state
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ''',
        [
          eventId,
          venueKey,
          sequence,
          hubEpoch,
          createdAt.millisecondsSinceEpoch,
          previousHash,
          eventHash,
          encrypted.nonce,
          encrypted.cipherText,
          encrypted.mac,
        ],
      );
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    final event = OfflineEvent(
      id: eventId,
      tenantId: draft.tenantId,
      venueId: draft.venueId,
      deviceId: draft.deviceId,
      staffId: draft.staffId,
      managerApprovalStaffId: draft.managerApprovalStaffId,
      type: draft.type,
      payload: draft.payload,
      createdAtUtc: createdAt,
      businessTimestampUtc: businessTimestamp,
      sequence: sequence,
      hubEpoch: hubEpoch,
      previousHash: previousHash,
      eventHash: eventHash,
      syncState: OfflineEventSyncState.pending,
    );
    _notifyChanged();
    return event;
  });

  @override
  Future<List<OfflineEvent>> pending({int limit = 250}) => _serial(() async {
    await _initializeInternal();
    final safeLimit = limit.clamp(1, 1000);
    final rows = _database!.select(
      '''
        SELECT * FROM offline_events
        WHERE sync_state IN (0, 1)
        ORDER BY created_at_utc_ms, sequence
        LIMIT ?
      ''',
      [safeLimit],
    );
    final events = <OfflineEvent>[];
    for (final row in rows) {
      events.add(await _decodeAndVerify(row));
    }
    return events;
  });

  @override
  Stream<List<OfflineEvent>> watchPending({int limit = 250}) async* {
    yield await pending(limit: limit);
    await for (final _ in _changes.stream) {
      yield await pending(limit: limit);
    }
  }

  @override
  Future<void> markInFlight(String eventId) =>
      _setState(eventId, OfflineEventSyncState.inFlight);

  @override
  Future<void> markSynced(String eventId, DateTime acknowledgedAtUtc) =>
      _serial(() async {
        await _initializeInternal();
        _database!.execute(
          '''
            UPDATE offline_events
            SET sync_state = 2, cloud_acknowledged_at_utc_ms = ?,
                quarantine_reason = NULL
            WHERE event_id = ? AND sync_state IN (0, 1)
          ''',
          [acknowledgedAtUtc.toUtc().millisecondsSinceEpoch, _eventId(eventId)],
        );
        _requireChanged(eventId);
        _notifyChanged();
      });

  @override
  Future<void> quarantine(String eventId, String reason) => _serial(() async {
    final safeReason = reason.trim();
    if (safeReason.isEmpty || safeReason.length > 500) {
      throw ArgumentError.value(
        reason,
        'reason',
        'Must contain 1–500 characters.',
      );
    }
    await _initializeInternal();
    _database!.execute(
      '''
        UPDATE offline_events SET sync_state = 3, quarantine_reason = ?
        WHERE event_id = ? AND sync_state != 2
      ''',
      [safeReason, _eventId(eventId)],
    );
    _requireChanged(eventId);
    _notifyChanged();
  });

  Future<void> _setState(
    String eventId,
    OfflineEventSyncState state,
  ) => _serial(() async {
    await _initializeInternal();
    _database!.execute(
      'UPDATE offline_events SET sync_state = ? WHERE event_id = ? AND sync_state = 0',
      [state.index, _eventId(eventId)],
    );
    _requireChanged(eventId);
    _notifyChanged();
  });

  Future<OfflineEvent> _decodeAndVerify(Row row) async {
    final associatedData = _associatedData(
      eventId: row['event_id'] as String,
      venueKey: row['venue_key'] as String,
      sequence: row['sequence'] as int,
      hubEpoch: row['hub_epoch'] as int,
      createdAtUtcMs: row['created_at_utc_ms'] as int,
      previousHash: row['previous_hash'] as String,
    );
    final encrypted = EncryptedOfflineEnvelope(
      nonce: Uint8List.fromList(row['nonce'] as List<int>),
      cipherText: Uint8List.fromList(row['cipher_text'] as List<int>),
      mac: Uint8List.fromList(row['mac'] as List<int>),
    );
    final expectedHash = await _crypto.eventHash(
      '$associatedData|${base64UrlEncode(encrypted.nonce)}|'
      '${base64UrlEncode(encrypted.cipherText)}|${base64UrlEncode(encrypted.mac)}',
    );
    if (expectedHash != row['event_hash']) {
      throw StateError('An offline event failed its integrity check.');
    }
    final clear = await _crypto.decryptJson(
      encrypted,
      associatedData: associatedData,
    );
    final payload = clear['payload'];
    if (payload is! Map) {
      throw StateError('An offline event payload is invalid.');
    }
    return OfflineEvent(
      id: row['event_id'] as String,
      tenantId: clear['tenantId'] as String,
      venueId: clear['venueId'] as String,
      deviceId: clear['deviceId'] as String,
      staffId: clear['staffId'] as String,
      managerApprovalStaffId: clear['managerApprovalStaffId'] as String?,
      type: clear['type'] as String,
      payload: Map<String, Object?>.from(payload),
      createdAtUtc: DateTime.fromMillisecondsSinceEpoch(
        row['created_at_utc_ms'] as int,
        isUtc: true,
      ),
      businessTimestampUtc: DateTime.parse(
        clear['businessTimestampUtc'] as String,
      ).toUtc(),
      sequence: row['sequence'] as int,
      hubEpoch: row['hub_epoch'] as int,
      previousHash: row['previous_hash'] as String,
      eventHash: row['event_hash'] as String,
      syncState: OfflineEventSyncState.values[row['sync_state'] as int],
      cloudAcknowledgedAtUtc: row['cloud_acknowledged_at_utc_ms'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['cloud_acknowledged_at_utc_ms'] as int,
              isUtc: true,
            ),
      quarantineReason: row['quarantine_reason'] as String?,
    );
  }

  void _requireChanged(String eventId) {
    if (_database!.updatedRows == 0) {
      throw StateError('Offline event $eventId was not in the expected state.');
    }
  }

  String _eventId(String value) {
    final trimmed = value.trim();
    if (!RegExp(r'^evt_[0-9]+_[a-f0-9]{32}$').hasMatch(trimmed)) {
      throw ArgumentError.value(value, 'eventId', 'Invalid offline event ID.');
    }
    return trimmed;
  }

  String _newEventId(DateTime timestamp) {
    final random = Random.secure();
    final suffix = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'evt_${timestamp.microsecondsSinceEpoch}_$suffix';
  }

  String _associatedData({
    required String eventId,
    required String venueKey,
    required int sequence,
    required int hubEpoch,
    required int createdAtUtcMs,
    required String previousHash,
  }) => '$eventId|$venueKey|$sequence|$hubEpoch|$createdAtUtcMs|$previousHash';

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operation = _operation.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> close() => _serial(() async {
    if (_closed) return;
    _closed = true;
    _database?.close();
    _database = null;
    _initialized = false;
    await _changes.close();
  });
}
