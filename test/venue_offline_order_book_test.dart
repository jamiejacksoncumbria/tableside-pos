import 'package:flutter_test/flutter_test.dart';
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
}
