import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_order_projection.dart';
import 'package:tableside_pos/offline/venue_hub_command_processor.dart';
import 'package:tableside_pos/offline/venue_offline_catalogue.dart';

void main() {
  final grant = VenueHubStaffGrant(
    staffId: 'staff-a',
    permissions: const {'order'},
    expiresAtUtc: DateTime.utc(2030),
    pinVersion: 1,
    membershipVersion: 1,
  );

  test(
    'canonical pricing ignores client-supplied names, prices and tax',
    () async {
      final catalogue = VenueOfflineCatalogue.fromSnapshot(_snapshot());
      final payload = await catalogue.validateEvent('order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'steak',
        'quantity': 2,
        'productName': 'Cheap fake steak',
        'unitPriceMinor': 1,
        'taxRateBasisPoints': 0,
        'variantId': 'large',
        'modifierSelections': [
          {'groupId': 'cooking', 'optionId': 'medium'},
        ],
      }, grant);
      expect(payload['productName'], 'Sirloin Steak');
      expect(payload['unitPriceMinor'], 2800);
      expect(payload['taxRateBasisPoints'], 2000);
      expect(payload['catalogueVersion'], 7);
    },
  );

  test('required modifier cannot be omitted', () async {
    final catalogue = VenueOfflineCatalogue.fromSnapshot(_snapshot());
    expect(
      () => catalogue.validateEvent('order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'steak',
        'quantity': 1,
        'variantId': 'large',
      }, grant),
      throwsA(isA<VenueOfflineCatalogueException>()),
    );
  });

  test('required printing fails closed without a matching route', () {
    final catalogue = VenueOfflineCatalogue.fromSnapshot(_snapshot());
    final order = projectOfflineOrder([
      _event(1, 'order.opened', {'orderId': 'order-a'}),
      _event(2, 'order.itemAdded', {
        'orderId': 'order-a',
        'lineId': 'line-a',
        'productId': 'steak',
        'productName': 'Sirloin Steak',
        'quantity': 1,
        'unitPriceMinor': 2500,
        'productionArea': 'kitchen',
      }),
    ]);
    expect(
      () => catalogue.validatePrintRoutes(order, const [
        'line-a',
      ], printRequired: true),
      throwsA(isA<VenueOfflineCatalogueException>()),
    );
  });
}

OfflineEvent _event(int sequence, String type, Map<String, Object?> payload) {
  final timestamp = DateTime.utc(2026, 9, 12, 12, 0, sequence);
  return OfflineEvent(
    id: 'evt-$sequence',
    tenantId: 'tenant-a',
    venueId: 'venue-a',
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
    hubEpoch: 1,
    previousHash: 'previous',
    eventHash: 'hash-$sequence',
    syncState: OfflineEventSyncState.pending,
  );
}

Map<String, Object?> _snapshot() => {
  'version': 7,
  'currencyCode': 'TRY',
  'modifierGroups': [
    {
      'id': 'cooking',
      'name': 'Cooking preference',
      'minimumSelections': 1,
      'maximumSelections': 1,
      'isAvailable': true,
      'options': [
        {
          'id': 'medium',
          'name': 'Medium',
          'priceDeltaMinor': 100,
          'isAvailable': true,
        },
      ],
    },
  ],
  'products': [
    {
      'id': 'steak',
      'name': 'Sirloin Steak',
      'priceMinor': 2500,
      'taxRateId': 'vat',
      'taxRateName': 'VAT',
      'taxRateBasisPoints': 2000,
      'productionArea': 'kitchen',
      'isAvailable': true,
      'modifierGroupIds': ['cooking'],
      'variants': [
        {
          'id': 'large',
          'name': 'Large',
          'priceDeltaMinor': 200,
          'isAvailable': true,
        },
      ],
    },
  ],
};
