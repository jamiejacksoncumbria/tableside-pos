import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_event_crypto.dart';
import 'package:tableside_pos/offline/offline_event_ledger.dart';
import 'package:tableside_pos/offline/offline_event_store_native.dart';
import 'package:tableside_pos/offline/offline_order_projection.dart';
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

  test('order ensure accepts a matching signed recovery baseline', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    addTearDown(store.close);
    final ledger = OfflineEventLedger.forTesting(store);
    await ledger.initialize();
    final baseline = await ledger.commit(
      OfflineEventDraft(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'hub-cloud-migration',
        staffId: 'cloud-verified-baseline',
        type: 'order.cloudBaseline',
        payload: <String, Object?>{
          'orderId': 'order-a',
          'sourceOfflineHubEpoch': 3,
          'openedAtUtc': '2026-10-13T10:00:00.000Z',
          'channel': 'dineIn',
          'tableId': 'table-a',
          'deliveryFeeMinor': 0,
          'lines': <Object?>[],
          'payments': <Object?>[],
        },
      ),
      hubEpoch: 3,
    );
    final orderBook = VenueOfflineOrderBook(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      hubEpoch: 3,
      ledger: ledger,
    );

    final acknowledged = await orderBook.commit(
      OfflineEventDraft(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'terminal-a',
        staffId: 'staff-a',
        type: 'order.opened',
        payload: <String, Object?>{
          'orderId': 'order-a',
          'channel': 'dineIn',
          'tableId': 'table-a',
        },
      ),
      3,
    );

    expect(acknowledged.id, baseline.id);
    expect(
      await ledger.eventsForVenue(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        hubEpoch: 3,
      ),
      hasLength(1),
    );
  });

  test('order ensure rejects a conflicting recovery location', () async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    addTearDown(store.close);
    final ledger = OfflineEventLedger.forTesting(store);
    await ledger.initialize();
    await ledger.commit(
      OfflineEventDraft(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'hub-cloud-migration',
        staffId: 'cloud-verified-baseline',
        type: 'order.cloudBaseline',
        payload: <String, Object?>{
          'orderId': 'order-a',
          'sourceOfflineHubEpoch': 3,
          'openedAtUtc': '2026-10-13T10:00:00.000Z',
          'channel': 'dineIn',
          'tableId': 'table-a',
          'deliveryFeeMinor': 0,
          'lines': <Object?>[],
          'payments': <Object?>[],
        },
      ),
      hubEpoch: 3,
    );
    final orderBook = VenueOfflineOrderBook(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      hubEpoch: 3,
      ledger: ledger,
    );

    expect(
      () => orderBook.commit(
        OfflineEventDraft(
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          deviceId: 'terminal-a',
          staffId: 'staff-a',
          type: 'order.opened',
          payload: <String, Object?>{
            'orderId': 'order-a',
            'channel': 'dineIn',
            'tableId': 'table-b',
          },
        ),
        3,
      ),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test(
    'redundant baseline cannot poison an already closed local order',
    () async {
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
    },
  );

  test(
    'recovery baseline preserves a legacy order location after close',
    () async {
      final database = sqlite3.openInMemory();
      final store = NativeOfflineEventStore(
        database: database,
        crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
      );
      addTearDown(store.close);
      final ledger = OfflineEventLedger.forTesting(store);
      await ledger.initialize();

      Future<void> append(String type, Map<String, Object?> payload) async {
        await ledger.commit(
          OfflineEventDraft(
            tenantId: 'tenant-a',
            venueId: 'venue-a',
            deviceId: 'hub-a',
            staffId: 'staff-a',
            type: type,
            payload: {'orderId': 'order-a', ...payload},
          ),
          hubEpoch: 3,
        );
      }

      // The local recovery shell predates the authoritative location carried by
      // the signed cloud baseline, which was appended after the local close.
      await append('order.opened', {'channel': 'dineIn'});
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
      await append('order.cloudBaseline', {
        'sourceOfflineHubEpoch': 3,
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
      });

      final order = (await VenueOfflineOrderBook(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        hubEpoch: 3,
        ledger: ledger,
      ).rebuild())['order-a']!;
      expect(order.isClosed, isTrue);
      expect(order.balanceDueMinor, 0);
      expect(order.tableId, 'table-a');
    },
  );

  test(
    'split event atomically creates a payable child and reduces parent',
    () async {
      final database = sqlite3.openInMemory();
      final store = NativeOfflineEventStore(
        database: database,
        crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
      );
      addTearDown(store.close);
      final ledger = OfflineEventLedger.forTesting(store);
      await ledger.initialize();
      final orderBook = VenueOfflineOrderBook(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        hubEpoch: 3,
        ledger: ledger,
      );

      Future<void> commit(String type, Map<String, Object?> payload) async {
        await orderBook.commit(
          OfflineEventDraft(
            tenantId: 'tenant-a',
            venueId: 'venue-a',
            deviceId: 'terminal-a',
            staffId: 'staff-a',
            type: type,
            payload: payload,
          ),
          3,
        );
      }

      await commit('order.opened', {
        'orderId': 'order-a',
        'channel': 'dineIn',
        'tableId': 'table-a',
      });
      await commit('order.itemsAdded', {
        'orderId': 'order-a',
        'items': [
          {
            'lineId': 'line-a',
            'productId': 'product-a',
            'productName': 'Curry',
            'quantity': 2,
            'unitPriceMinor': 1500,
          },
          {
            'lineId': 'line-b',
            'productId': 'product-b',
            'productName': 'Rice',
            'quantity': 1,
            'unitPriceMinor': 500,
          },
        ],
      });
      await commit('order.sent', {
        'orderId': 'order-a',
        'lineIds': ['line-a', 'line-b'],
      });
      await commit('order.splitCreated', {
        'orderId': 'order-a',
        'splitOrderId': 'split-a',
        'splitLines': [
          {'lineId': 'line-a', 'quantity': 1},
        ],
      });

      var orders = await orderBook.rebuild();
      expect(orders.keys, containsAll(['order-a', 'split-a']));
      expect(orders['order-a']!.totalMinor, 2000);
      expect(orders['order-a']!.openSplitOrderIds, ['split-a']);
      expect(orders['split-a']!.totalMinor, 1500);
      expect(orders['split-a']!.splitFromOrderId, 'order-a');
      expect(orders['split-a']!.lines.values.single.sent, isTrue);

      final splitEventCount = (await ledger.eventsForVenue(
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        hubEpoch: 3,
      )).length;
      final ensuredChild = await orderBook.commit(
        OfflineEventDraft(
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          deviceId: 'terminal-b',
          staffId: 'staff-a',
          type: 'order.opened',
          payload: const <String, Object?>{
            'orderId': 'split-a',
            'channel': 'dineIn',
            'tableId': 'table-a',
          },
        ),
        3,
      );
      expect(ensuredChild.type, 'order.splitCreated');
      expect(
        (await ledger.eventsForVenue(
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          hubEpoch: 3,
        )).length,
        splitEventCount,
      );

      await commit('payment.batchRecorded', {
        'orderId': 'split-a',
        'splitFromOrderId': 'order-a',
        'batchId': 'payment-split-a',
        'payments': [
          {
            'paymentId': 'payment-split-a-0',
            'baseAmountMinor': 1500,
            'tenderedAmountMinor': 1500,
            'method': 'cash',
            'currencyCode': 'TRY',
            'exchangeRateToBase': '1',
          },
        ],
        'closeIfSettled': true,
        'receiptNumber': 'OFF-SPLIT-A',
      });

      orders = await orderBook.rebuild();
      expect(orders['split-a']!.isClosed, isTrue);
      expect(orders['order-a']!.openSplitOrderIds, isEmpty);
    },
  );
}
