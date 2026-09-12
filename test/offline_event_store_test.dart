import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_event_crypto.dart';
import 'package:tableside_pos/offline/offline_event_store_native.dart';

void main() {
  test('durably queued events round-trip with encrypted payloads', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(
        Uint8List.fromList(List<int>.generate(64, (index) => index)),
      ),
    );
    addTearDown(store.close);
    await store.initialize();

    final saved = await store.append(
      OfflineEventDraft(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'device-a',
        staffId: 'staff-a',
        type: 'order.itemAdded',
        payload: const {'orderId': 'order-a', 'quantity': 2},
      ),
      hubEpoch: 1,
    );

    final pending = await store.pending();
    expect(pending, hasLength(1));
    expect(pending.single.id, saved.id);
    expect(pending.single.sequence, 1);
    expect(pending.single.payload, {'orderId': 'order-a', 'quantity': 2});
    expect(pending.single.deviceObservedAtUtc, isNotNull);
    expect(pending.single.timeAuthority, OfflineTimeAuthority.deviceUnverified);
    final raw = database.select(
      'SELECT cipher_text FROM offline_events WHERE event_id = ?',
      [saved.id],
    );
    expect(
      String.fromCharCodes(raw.single['cipher_text'] as List<int>),
      isNot(contains('order-a')),
    );
  });

  test('event hash detects local database tampering', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    addTearDown(store.close);
    await store.initialize();
    final saved = await store.append(
      OfflineEventDraft(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'device-a',
        staffId: 'staff-a',
        type: 'payment.recorded',
        payload: const {'amountMinor': 1200},
      ),
      hubEpoch: 1,
    );

    database.execute(
      'UPDATE offline_events SET event_hash = ? WHERE event_id = ?',
      ['tampered', saved.id],
    );

    await expectLater(store.pending(), throwsA(isA<StateError>()));
  });

  test('offline drafts reject missing security scope', () {
    expect(
      () => OfflineEventDraft(
        tenantId: '',
        venueId: 'venue-a',
        deviceId: 'device-a',
        staffId: 'staff-a',
        type: 'order.created',
        payload: const {},
      ),
      throwsArgumentError,
    );
  });

  test('venue snapshots are encrypted, scoped and versioned', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    addTearDown(store.close);
    await store.initialize();
    await store.saveSnapshot(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      kind: 'catalogue',
      version: 2,
      value: const {
        'product-a': {'priceMinor': 1500},
      },
    );
    final saved = await store.readSnapshot(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      kind: 'catalogue',
    );
    expect(saved!['version'], 2);
    expect((saved['value'] as Map)['product-a'], {'priceMinor': 1500});
    final raw = database.select('SELECT cipher_text FROM offline_snapshots');
    expect(
      String.fromCharCodes(raw.single['cipher_text'] as List<int>),
      isNot(contains('product-a')),
    );
    expect(
      await store.readSnapshot(
        tenantId: 'tenant-a',
        venueId: 'venue-b',
        kind: 'catalogue',
      ),
      isNull,
    );
  });
}
