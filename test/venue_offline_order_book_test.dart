import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_event_crypto.dart';
import 'package:tableside_pos/offline/offline_event_ledger.dart';
import 'package:tableside_pos/offline/offline_event_store_native.dart';
import 'package:tableside_pos/offline/venue_offline_order_book.dart';

void main() {
  test('order ensure ignores mutable fulfilment enrichment', () {
    final first = offlineRetrySemanticPayload('order.opened', const {
      'orderId': 'order-a',
      'channel': 'delivery',
      'customerId': 'customer-a',
      'serviceAreaId': 'area-a',
      'deliveryFeeMinor': 200,
      'remoteCommandId': 'remote-a',
    });
    final retry = offlineRetrySemanticPayload('order.opened', const {
      'orderId': 'order-a',
      'channel': 'delivery',
      'customerId': 'customer-a',
      'customerName': 'Jamie Jackson',
      'serviceAreaId': 'area-a',
      'deliveryFeeMinor': 250,
      'assignedDriverId': 'driver-a',
      'remoteCommandId': 'remote-b',
    });
    expect(retry, first);
  });

  test('order ensure retains immutable location identity', () {
    final tableOne = offlineRetrySemanticPayload('order.opened', const {
      'orderId': 'order-a',
      'tableId': 'table-1',
      'channel': 'dineIn',
    });
    final tableTwo = offlineRetrySemanticPayload('order.opened', const {
      'orderId': 'order-a',
      'tableId': 'table-2',
      'channel': 'dineIn',
    });
    expect(tableTwo, isNot(tableOne));
  });

  test('redundant baseline cannot poison an already closed local order', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    addTearDown(store.close);
    final ledger = OfflineEventLedger.forTesting(store);
    await ledger.initialize();

    const tenantId = 'tenant-a';
    const venueId = 'venue-a';
    const orderId = 'order-a';
    const hubEpoch = 3;
    Future<void> append(String type, Map<String, Object?> payload) async {
      await ledger.commit(
        OfflineEventDraft(
          tenantId: tenantId,
          venueId: venueId,
          deviceId: 'hub-a',
          staffId: 'staff-a',
          type: type,
          payload: {'orderId': orderId, ...payload},
        ),
        hubEpoch: hubEpoch,
      );
    }

    await append('order.opened', {'channel': 'dineIn', 'tableId': 'table-a'});
    await append('order.itemAdded', {
      'lineId': 'line-a',
      'productId': 'product-a',
      'productName': 'Meal',
      'quantity': 1,
      'unitPriceMinor': 2000,
    });
    await append('payment.recorded', {
      'paymentId': 'payment-a',
      'baseAmountMinor': 2000,
      'method': 'cash',
      'currencyCode': 'TRY',
    });
    await append('order.closed', {'receiptNumber': 'R-1'});

    final conflictingBaseline = <String, Object?>{
      'orderId': orderId,
      'sourceOfflineHubEpoch': hubEpoch,
      'openedAtUtc': '2026-10-13T10:00:00.000Z',
      'channel': 'dineIn',
      'tableId': 'table-a',
      'deliveryFeeMinor': 0,
      'lines': [
        {
          'id': 'line-a',
          'productId': 'product-a',
          'name': 'Meal',
          'quantity': 1,
          'unitPriceMinor': 2000,
          'sent': true,
        },
        {
          'id': 'cloud-only-line',
          'productId': 'product-b',
          'name': 'Cloud-only item',
          'quantity': 1,
          'unitPriceMinor': 500,
          'sent': true,
        },
      ],
      'payments': [
        {
          'id': 'payment-a',
          'baseAmountMinor': 2000,
          'tenderedAmountMinor': 2000,
          'method': 'cash',
          'currencyCode': 'TRY',
        },
      ],
    };
    await append('order.cloudBaseline', conflictingBaseline);

    final orderBook = VenueOfflineOrderBook(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
      ledger: ledger,
    );
    final beforeRefresh = await orderBook.rebuild();
    expect(beforeRefresh[orderId]!.isClosed, isTrue);
    expect(beforeRefresh[orderId]!.balanceDueMinor, 0);

    await orderBook.installCloudBaselines({
      'openOrders': [conflictingBaseline],
    });

    final rebuilt = await orderBook.rebuild();
    expect(rebuilt[orderId]!.isClosed, isTrue);
    expect(rebuilt[orderId]!.balanceDueMinor, 0);
    final activeEvents = await ledger.eventsForVenue(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
    );
    expect(
      activeEvents.where((event) => event.type == 'order.cloudBaseline'),
      hasLength(1),
    );
  });
}
