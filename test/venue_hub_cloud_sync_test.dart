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
