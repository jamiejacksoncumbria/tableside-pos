import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_order_projection.dart';

void main() {
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
      throwsA(isA<OfflineProjectionException>()),
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
}

OfflineEvent _event(
  int sequence,
  String type,
  Map<String, Object?> payload, {
  int hubEpoch = 1,
  String venueId = 'venue-a',
}) {
  final timestamp = DateTime.utc(2026, 9, 12, 12, 0, sequence);
  return OfflineEvent(
    id: 'evt_$sequence',
    tenantId: 'tenant-a',
    venueId: venueId,
    deviceId: 'device-a',
    staffId: 'staff-a',
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
