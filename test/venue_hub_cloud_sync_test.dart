import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_event_crypto.dart';
import 'package:tableside_pos/offline/offline_event_ledger.dart';
import 'package:tableside_pos/offline/offline_event_store_native.dart';
import 'package:tableside_pos/offline/venue_hub_cloud_sync.dart';

void main() {
  test('a flush requested during upload is not lost', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
      database: database,
    );
    final ledger = OfflineEventLedger.forTesting(store);
    await ledger.initialize();
    addTearDown(store.close);

    await ledger.commit(_draft('line-a'), hubEpoch: 1);
    final firstUploadStarted = Completer<void>();
    final releaseFirstUpload = Completer<void>();
    final secondUploadCompleted = Completer<void>();
    var uploadCount = 0;
    final sync = VenueHubCloudSync(
      ledger: ledger,
      upload: (events) async {
        uploadCount++;
        if (uploadCount == 1) {
          firstUploadStarted.complete();
          await releaseFirstUpload.future;
        } else if (!secondUploadCompleted.isCompleted) {
          secondUploadCompleted.complete();
        }
        return VenueHubCloudUploadResult(
          acknowledgedEventIds: events.map((event) => event.id).toSet(),
        );
      },
    );
    addTearDown(sync.dispose);

    final firstFlush = sync.flush();
    await firstUploadStarted.future;
    await ledger.commit(_draft('line-b'), hubEpoch: 1);

    // This is the same wake-up the runtime receives from watchPending while
    // its previous upload is still in progress.
    await sync.flush();
    releaseFirstUpload.complete();
    await firstFlush;
    await secondUploadCompleted.future.timeout(const Duration(seconds: 2));

    expect(uploadCount, 2);
    final pendingDeadline = DateTime.now().add(const Duration(seconds: 2));
    while ((await ledger.pending()).isNotEmpty &&
        DateTime.now().isBefore(pendingDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await ledger.pending(), isEmpty);
  });

  test(
    'cloud outage leaves events durable across a hub sync restart',
    () async {
      final database = sqlite3.openInMemory();
      final store = NativeOfflineEventStore(
        crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
        database: database,
      );
      final ledger = OfflineEventLedger.forTesting(store);
      await ledger.initialize();
      addTearDown(store.close);

      final committed = await ledger.commit(
        _draft('line-power-loss'),
        hubEpoch: 1,
      );
      final offlineSync = VenueHubCloudSync(
        ledger: ledger,
        retryDelay: const Duration(hours: 1),
        maximumRetryDelay: const Duration(hours: 1),
        upload: (_) async => throw StateError('Cloud connection unavailable.'),
      );
      await offlineSync.flush();
      offlineSync.dispose();

      final pendingAfterFailure = await ledger.pending();
      expect(pendingAfterFailure, hasLength(1));
      expect(pendingAfterFailure.single.id, committed.id);
      expect(
        pendingAfterFailure.single.syncState,
        OfflineEventSyncState.pending,
      );

      var recoveredUploads = 0;
      final restartedSync = VenueHubCloudSync(
        ledger: ledger,
        upload: (events) async {
          recoveredUploads++;
          expect(events.map((event) => event.id), <String>[committed.id]);
          return VenueHubCloudUploadResult(
            acknowledgedEventIds: <String>{committed.id},
          );
        },
      );
      addTearDown(restartedSync.dispose);

      expect(await restartedSync.flush(), 1);
      expect(recoveredUploads, 1);
      expect(await ledger.pending(), isEmpty);
    },
  );

  test(
    'partial cloud acknowledgement retries only unconfirmed events',
    () async {
      final database = sqlite3.openInMemory();
      final store = NativeOfflineEventStore(
        crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
        database: database,
      );
      final ledger = OfflineEventLedger.forTesting(store);
      await ledger.initialize();
      addTearDown(store.close);

      final first = await ledger.commit(_draft('line-first'), hubEpoch: 1);
      final second = await ledger.commit(_draft('line-second'), hubEpoch: 1);
      final interruptedSync = VenueHubCloudSync(
        ledger: ledger,
        retryDelay: const Duration(hours: 1),
        maximumRetryDelay: const Duration(hours: 1),
        upload: (_) async =>
            VenueHubCloudUploadResult(acknowledgedEventIds: <String>{first.id}),
      );

      expect(await interruptedSync.flush(), 1);
      interruptedSync.dispose();
      final pending = await ledger.pending();
      expect(pending.map((event) => event.id), <String>[second.id]);

      final resumedSync = VenueHubCloudSync(
        ledger: ledger,
        upload: (events) async {
          expect(events.map((event) => event.id), <String>[second.id]);
          return VenueHubCloudUploadResult(
            acknowledgedEventIds: <String>{second.id},
          );
        },
      );
      addTearDown(resumedSync.dispose);

      expect(await resumedSync.flush(), 1);
      expect(await ledger.pending(), isEmpty);
    },
  );
}

OfflineEventDraft _draft(String lineId) => OfflineEventDraft(
  tenantId: 'tenant-a',
  venueId: 'venue-a',
  deviceId: 'hub-a',
  staffId: 'staff-a',
  type: 'order.itemAdded',
  payload: <String, Object?>{
    'orderId': 'order-a',
    'lineId': lineId,
    'productId': 'product-a',
  },
);
