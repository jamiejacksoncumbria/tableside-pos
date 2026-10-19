import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_order_projection.dart';

void main() {
  test('basket batch adds every line atomically to the projection', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemsAdded', {
        'orderId': 'order-a',
        'items': [
          {
            'orderId': 'order-a',
            'lineId': 'line-a',
            'productId': 'product-a',
            'productName': 'Starter',
            'quantity': 1,
            'unitPriceMinor': 500,
          },
          {
            'orderId': 'order-a',
            'lineId': 'line-b',
            'productId': 'product-b',
            'productName': 'Main',
            'quantity': 2,
            'unitPriceMinor': 1200,
          },
        ],
      }),
    ]);

    expect(projection.lines.keys, containsAll(['line-a', 'line-b']));
    expect(projection.totalMinor, 2900);
  });

  test('basket batch rejects duplicate line identities', () {
    expect(
      () => projectOfflineOrder([
        _event(1, 'order.opened', {'orderId': 'order-a'}),
        _event(2, 'order.itemsAdded', {
          'orderId': 'order-a',
          'items': [
            {
              'lineId': 'line-a',
              'productId': 'product-a',
              'productName': 'Starter',
              'quantity': 1,
              'unitPriceMinor': 500,
            },
            {
              'lineId': 'line-a',
              'productId': 'product-b',
              'productName': 'Main',
              'quantity': 1,
              'unitPriceMinor': 1200,
            },
          ],
        }),
      ]),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test('replay produces a paid, closed deterministic order', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Chicken Curry',
        'quantity': 2,
        'unitPriceMinor': 1500,
      }),
      _event(3, 'order.sent', {
        'orderId': 'order-a',
        'lineIds': ['line-a'],
      }),
      _event(4, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 3000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
      _event(5, 'order.closed', {'orderId': 'order-a'}),
    ]);

    expect(projection.totalMinor, 3000);
    expect(projection.paidMinor, 3000);
    expect(projection.balanceDueMinor, 0);
    expect(projection.lines['line-a']!.sent, isTrue);
    expect(projection.isClosed, isTrue);
  });

  test('partial payment keeps the balance open', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 2000,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 750,
        'method': 'card',
        'currencyCode': 'TRY',
      }),
    ]);

    expect(projection.balanceDueMinor, 1250);
    expect(projection.isClosed, isFalse);
    expect(projection.payments.single.tenderedAmountMinor, 750);
    expect(projection.payments.single.exchangeRateToBase, '1');
  });

  test('payment batch records split tender and closes atomically', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 2000,
      }),
      _event(3, 'payment.batchRecorded', {
        'orderId': 'order-a',
        'batchId': 'checkout-a',
        'payments': [
          {
            'paymentId': 'checkout-a-0',
            'baseAmountMinor': 750,
            'method': 'cash',
            'currencyCode': 'TRY',
          },
          {
            'paymentId': 'checkout-a-1',
            'baseAmountMinor': 1250,
            'method': 'cardTerminal',
            'currencyCode': 'TRY',
          },
        ],
        'closeIfSettled': true,
        'receiptNumber': 'OFF-2-checkout-a',
      }),
    ]);

    expect(projection.payments, hasLength(2));
    expect(projection.paidMinor, 2000);
    expect(projection.balanceDueMinor, 0);
    expect(projection.isClosed, isTrue);
    expect(projection.receiptNumber, 'OFF-2-checkout-a');
  });

  test('payment batch is rejected in full when split tender overpays', () {
    final events = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 2000,
      }),
      _event(3, 'payment.batchRecorded', {
        'orderId': 'order-a',
        'batchId': 'checkout-a',
        'payments': [
          {
            'paymentId': 'checkout-a-0',
            'baseAmountMinor': 1000,
            'method': 'cash',
            'currencyCode': 'TRY',
          },
          {
            'paymentId': 'checkout-a-1',
            'baseAmountMinor': 1500,
            'method': 'cardTerminal',
            'currencyCode': 'TRY',
          },
        ],
        'closeIfSettled': true,
      }),
    ];

    expect(
      () => projectOfflineOrder(events),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test('manager adjustment changes the authoritative hub balance', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a', 'tableId': 'table-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 2,
        'unitPriceMinor': 1500,
      }),
      _event(3, 'order.lineAdjusted', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'operation': 'discountUnitAmount',
        'valueMinor': 250,
        'reason': 'Manager goodwill',
      }),
    ]);

    expect(projection.lines.values.single.unitPriceMinor, 1250);
    expect(projection.totalMinor, 2500);
    expect(projection.balanceDueMinor, 2500);
  });

  test('manager can remove the final item from an unpaid order', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Mistake',
        'quantity': 1,
        'unitPriceMinor': 1500,
      }),
      _event(3, 'order.lineAdjusted', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'operation': 'remove',
        'reason': 'Added by mistake',
      }),
    ]);

    expect(projection.lines, isEmpty);
    expect(projection.totalMinor, 0);
    expect(projection.balanceDueMinor, 0);
  });

  test('empty unpaid order can be cancelled without creating a sale', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a', 'tableId': 'table-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Mistake',
        'quantity': 1,
        'unitPriceMinor': 1500,
      }),
      _event(3, 'order.lineAdjusted', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'operation': 'remove',
        'reason': 'Added by mistake',
      }),
      _event(4, 'order.cancelled', {
        'orderId': 'order-a',
        'reason': 'All items removed',
      }),
    ]);

    expect(projection.lines, isEmpty);
    expect(projection.payments, isEmpty);
    expect(projection.isClosed, isTrue);
    expect(projection.receiptNumber, isNull);
  });

  test('order cancellation rejects an order which still has an item', () {
    expect(
      () => projectOfflineOrder([
        _event(1, 'order.opened', {'orderId': 'order-a'}),
        _event(2, 'order.itemAdded', {
          'orderId': 'order-a',
          'lineId': 'line-a',
          'productId': 'product-a',
          'productName': 'Meal',
          'quantity': 1,
          'unitPriceMinor': 1500,
        }),
        _event(3, 'order.cancelled', {
          'orderId': 'order-a',
          'reason': 'Invalid cancellation',
        }),
      ]),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test('manager adjustment cannot reduce a bill below recorded payments', () {
    final events = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1500,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
      _event(4, 'order.lineAdjusted', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'operation': 'setUnitPrice',
        'valueMinor': 500,
        'reason': 'Invalid reduction',
      }),
    ];

    expect(
      () => projectOfflineOrder(events),
      throwsA(
        isA<OfflineProjectionException>().having(
          (error) => error.message,
          'message',
          contains('payments already recorded'),
        ),
      ),
    );
  });

  test('delivery fee is included in payment and close validation', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {
        'orderId': 'order-a',
        'channel': 'delivery',
        'customerId': 'customer-a',
        'customerName': 'Delivery Customer',
        'deliveryAddress': 'Kyrenia Centre',
        'serviceAreaId': 'kyrenia',
        'serviceAreaName': 'Kyrenia',
        'deliveryFeeMinor': 250,
      }),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1250,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
      _event(4, 'order.closed', {'orderId': 'order-a'}),
    ]);

    expect(projection.totalMinor, 1250);
    expect(projection.paidMinor, 1250);
    expect(projection.balanceDueMinor, 0);
    expect(projection.isClosed, isTrue);
  });

  test('replacement hub repairs a legacy order before replaying payment', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {
        'orderId': 'order-a',
        'channel': 'delivery',
        'customerId': 'customer-a',
        'customerName': 'Jamie Jackson',
        'deliveryAddress': 'Kyrenia Centre',
      }, hubEpoch: 3),
      _event(2, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 50000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }, hubEpoch: 3),
      _event(3, 'order.cloudBaseline', {
        'orderId': 'order-a',
        'sourceOfflineHubEpoch': 2,
        'openedAtUtc': '2026-09-12T11:00:00.000Z',
        'channel': 'delivery',
        'customerId': 'customer-a',
        'customerName': 'Jamie Jackson',
        'deliveryAddress': 'Kyrenia Centre',
        'deliveryFeeMinor': 0,
        'lines': [
          {
            'id': 'line-a',
            'productId': 'product-a',
            'name': 'Prawn Salad',
            'quantity': 1,
            'unitPriceMinor': 50000,
            'sent': true,
          },
        ],
        'payments': <Object?>[],
      }, hubEpoch: 3),
    ]);

    expect(projection.lines.values.single.name, 'Prawn Salad');
    expect(projection.totalMinor, 50000);
    expect(projection.paidMinor, 50000);
    expect(projection.balanceDueMinor, 0);
  });

  test('same-epoch cloud baseline replays synced mutations idempotently', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}, hubEpoch: 3),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 2000,
      }, hubEpoch: 3),
      _event(3, 'order.itemQuantityChanged', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'quantity': 2,
      }, hubEpoch: 3),
      _event(4, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }, hubEpoch: 3),
      _event(5, 'order.cloudBaseline', {
        'orderId': 'order-a',
        'sourceOfflineHubEpoch': 3,
        'openedAtUtc': '2026-09-12T11:00:00.000Z',
        'channel': 'dineIn',
        'tableId': 'table-a',
        'deliveryFeeMinor': 0,
        'lines': [
          {
            'id': 'line-a',
            'productId': 'product-a',
            'name': 'Meal',
            'quantity': 2,
            'unitPriceMinor': 2000,
            'sent': false,
          },
        ],
        'payments': [
          {
            'id': 'payment-a',
            'baseAmountMinor': 1000,
            'tenderedAmountMinor': 1000,
            'method': 'cash',
            'currencyCode': 'TRY',
          },
        ],
      }, hubEpoch: 3),
    ]);

    expect(projection.lines.values.single.quantity, 2);
    expect(projection.totalMinor, 4000);
    expect(projection.paidMinor, 1000);
    expect(projection.balanceDueMinor, 3000);
  });

  test('interleaved global ledger sequences remain valid per order', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(3, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }),
      _event(7, 'order.sent', {
        'orderId': 'order-a',
        'lineIds': ['line-a'],
      }),
    ]);

    expect(projection.lastSequence, 7);
    expect(projection.lines.values.single.sent, isTrue);
  });

  test('overpayment and stale hub generations fail closed', () {
    final overpayment = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1001,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
    ];
    expect(
      () => projectOfflineOrder(overpayment),
      throwsA(
        isA<OfflineProjectionException>().having(
          (error) => error.message,
          'message',
          contains('attempted 1001 minor units; remaining 1000'),
        ),
      ),
    );

    final stale = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }, hubEpoch: 2),
    ];
    expect(
      () => projectOfflineOrder(stale),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test('events after closure and cross-venue events fail closed', () {
    final base = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
      _event(4, 'order.closed', {'orderId': 'order-a'}),
      _event(5, 'order.itemQuantityChanged', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'quantity': 2,
      }),
    ];
    expect(
      () => projectOfflineOrder(base),
      throwsA(isA<OfflineProjectionException>()),
    );

    final crossVenue = [
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }, venueId: 'venue-b'),
    ];
    expect(
      () => projectOfflineOrder(crossVenue),
      throwsA(isA<OfflineProjectionException>()),
    );
  });

  test(
    'delivery projection preserves customer, schedule, and driver state',
    () {
      final projection = projectOfflineOrder([
        _event(1, 'order.opened', {
          'orderId': 'order-a',
          'channel': 'delivery',
          'customerId': 'customer-a',
          'customerName': 'Jamie Jackson',
          'customerPhone': '+905551234567',
          'deliveryAddress': 'Kyrenia Centre',
          'serviceAreaId': 'kyrenia',
          'serviceAreaName': 'Kyrenia',
          'deliveryFeeMinor': 15000,
          'scheduledForUtc': '2026-09-12T18:30:00.000Z',
        }),
        _event(2, 'order.fulfilmentChanged', {
          'orderId': 'order-a',
          'status': 'assigned',
          'driverId': 'driver-a',
          'managerAuthorized': true,
        }, staffId: 'manager-a'),
        _event(3, 'order.fulfilmentChanged', {
          'orderId': 'order-a',
          'status': 'outForDelivery',
        }, staffId: 'driver-a'),
      ]);

      expect(projection.channel, 'delivery');
      expect(projection.customerName, 'Jamie Jackson');
      expect(projection.deliveryAddress, 'Kyrenia Centre');
      expect(projection.scheduledForUtc, DateTime.utc(2026, 9, 12, 18, 30));
      expect(projection.assignedDriverId, 'driver-a');
      expect(projection.fulfilmentStatus, 'outForDelivery');
    },
  );

  test('paid delivery can continue its audited fulfilment workflow', () {
    final projection = projectOfflineOrder([
      _event(1, 'order.opened', {
        'orderId': 'order-a',
        'channel': 'delivery',
        'customerId': 'customer-a',
        'customerName': 'Jamie Jackson',
        'deliveryAddress': 'Kyrenia Centre',
        'serviceAreaId': 'kyrenia',
        'serviceAreaName': 'Kyrenia',
      }),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'product-a',
        'productName': 'Meal',
        'quantity': 1,
        'unitPriceMinor': 1000,
      }),
      _event(3, 'payment.recorded', {
        'orderId': 'order-a',
        'paymentId': 'payment-a',
        'baseAmountMinor': 1000,
        'method': 'cash',
        'currencyCode': 'TRY',
      }),
      _event(4, 'order.closed', {'orderId': 'order-a'}),
      _event(5, 'order.fulfilmentChanged', {
        'orderId': 'order-a',
        'status': 'assigned',
        'driverId': 'driver-a',
        'managerAuthorized': true,
      }, staffId: 'manager-a'),
    ]);

    expect(projection.isClosed, isTrue);
    expect(projection.balanceDueMinor, 0);
    expect(projection.assignedDriverId, 'driver-a');
    expect(projection.fulfilmentStatus, 'assigned');
  });

  test(
    'legacy delivery orders remain replayable after service-area upgrade',
    () {
      final projection = projectOfflineOrder([
        _event(1, 'order.opened', {
          'orderId': 'order-a',
          'channel': 'delivery',
          'customerId': 'customer-a',
          'customerName': 'Legacy Customer',
          'deliveryAddress': 'Old free-text address',
        }),
        _event(2, 'order.fulfilmentChanged', {
          'orderId': 'order-a',
          'status': 'readyForCollection',
          'managerAuthorized': true,
        }, staffId: 'manager-a'),
      ]);

      expect(projection.channel, 'delivery');
      expect(projection.serviceAreaId, isNull);
      expect(projection.deliveryFeeMinor, 0);
      expect(projection.fulfilmentStatus, 'readyForCollection');
    },
  );

  test('an unassigned driver cannot claim an offline delivery', () {
    final events = [
      _event(1, 'order.opened', {
        'orderId': 'order-a',
        'channel': 'delivery',
        'customerId': 'customer-a',
        'customerName': 'Jamie Jackson',
        'deliveryAddress': 'Kyrenia Centre',
        'serviceAreaId': 'kyrenia',
        'serviceAreaName': 'Kyrenia',
        'deliveryFeeMinor': 15000,
      }),
      _event(2, 'order.fulfilmentChanged', {
        'orderId': 'order-a',
        'status': 'outForDelivery',
      }, staffId: 'driver-a'),
    ];
    expect(
      () => projectOfflineOrder(events),
      throwsA(isA<OfflineProjectionException>()),
    );
  });
}

OfflineEvent _event(
  int sequence,
  String type,
  Map<String, Object?> payload, {
  int hubEpoch = 1,
  String venueId = 'venue-a',
  String staffId = 'staff-a',
}) {
  final timestamp = DateTime.utc(2026, 9, 12, 12, 0, sequence);
  return OfflineEvent(
    id: 'evt_$sequence',
    tenantId: 'tenant-a',
    venueId: venueId,
    deviceId: 'device-a',
    staffId: staffId,
    type: type,
    payload: payload,
    createdAtUtc: timestamp,
    deviceObservedAtUtc: timestamp,
    timeAuthority: OfflineTimeAuthority.venueHub,
    clockSkewMillis: 0,
    businessTimestampUtc: timestamp,
    sequence: sequence,
    hubEpoch: hubEpoch,
    previousHash: sequence == 1 ? 'GENESIS' : 'hash-${sequence - 1}',
    eventHash: 'hash-$sequence',
    syncState: OfflineEventSyncState.pending,
  );
}
