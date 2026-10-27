import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/fulfilment/fulfilment_domain.dart';
import 'package:tableside_pos/features/pos/domain.dart';
import 'package:tableside_pos/offline/venue_hub_offline_view.dart';

void main() {
  test(
    'catalogue stream updates a screen opened before snapshot install',
    () async {
      final view = VenueHubOfflineView.instance..clear();
      final expectation = expectLater(
        view.productStream().take(2),
        emitsInOrder([
          isEmpty,
          predicate<List<Object>>(
            (products) => products.length == 1,
            'one installed product',
          ),
        ]),
      );

      await Future<void>.delayed(Duration.zero);
      view.install({
        'products': [
          {
            'id': 'coffee',
            'name': 'Coffee',
            'priceMinor': 250,
            'sectionIds': <String>[],
            'productionArea': 'bar',
            'isAvailable': true,
            'isArchived': false,
            'variants': <Object?>[],
            'modifierGroupIds': <String>[],
            'stockComponents': <Object?>[],
          },
        ],
      });

      await expectation;
      view.clear();
    },
  );

  test('hub snapshot supplies fulfilment customers and settings', () async {
    final view = VenueHubOfflineView.instance..clear();
    final customerExpectation = expectLater(
      view.customerStream.take(2),
      emitsInOrder([
        isEmpty,
        predicate<List<Object>>(
          (customers) => customers.length == 1,
          'one installed customer',
        ),
      ]),
    );
    final settingsExpectation = expectLater(
      view.fulfilmentSettingsStream.take(2),
      emitsInOrder([
        predicate<VenueFulfilmentSettings>(
          (value) =>
              value.collectionEnabled == false &&
              value.deliveryEnabled == false,
          'disabled defaults',
        ),
        predicate<VenueFulfilmentSettings>(
          (value) =>
              value.collectionEnabled == true &&
              value.deliveryEnabled == true &&
              value.serviceAreas.length == 1,
          'installed fulfilment settings',
        ),
      ]),
    );

    await Future<void>.delayed(Duration.zero);
    view.install({
      'collectionEnabled': true,
      'deliveryEnabled': true,
      'serviceAreas': [
        {
          'id': 'kyrenia',
          'name': 'Kyrenia',
          'deliveryFeeMinor': 100,
          'minimumOrderMinor': 500,
          'estimatedMinutes': 35,
          'active': true,
        },
      ],
      'venueCustomers': [
        {
          'id': 'customer-1',
          'displayName': 'Test Customer',
          'phoneNumbers': ['+905551234567'],
          'email': 'test@example.com',
          'claimStatus': 'unclaimed',
          'addresses': [
            {
              'id': 'address-1',
              'label': 'Home',
              'country': 'North Cyprus',
              'town': 'Kyrenia',
              'area': 'Central',
              'addressLines': '1 Test Street',
              'notes': '',
            },
          ],
        },
      ],
    });

    await customerExpectation;
    await settingsExpectation;
    expect(view.customers.single.displayName, 'Test Customer');
    expect(view.fulfilmentSettings.serviceAreas.single.name, 'Kyrenia');
    view.clear();
  });

  test('hub order stream publishes accepted and closed projections', () async {
    final view = VenueHubOfflineView.instance..clear();
    final expectation = expectLater(
      view.orderStream.take(3),
      emitsInOrder([
        isEmpty,
        predicate<List<PosOrder>>(
          (orders) =>
              orders.single.tableId == 'table-7' &&
              orders.single.status == OrderStatus.open,
          'open table projection',
        ),
        predicate<List<PosOrder>>(
          (orders) => orders.single.status == OrderStatus.closed,
          'closed table projection',
        ),
      ]),
    );

    Map<String, Object?> order({required bool closed}) => {
      'orderId': 'order-1',
      'tenantId': 'tenant-1',
      'venueId': 'venue-1',
      'tableId': 'table-7',
      'openedAtUtc': '2026-10-16T12:00:00.000Z',
      'isClosed': closed,
      'lines': <Object?>[],
      'payments': <Object?>[],
    };

    await Future<void>.delayed(Duration.zero);
    view.installOrders([order(closed: false)]);
    view.installOrders([order(closed: true)]);
    await expectation;
    view.clear();
  });

  test('sent local lines appear immediately on the offline order flow', () {
    final view = VenueHubOfflineView.instance..clear();
    view.install({
      'products': [
        {
          'id': 'curry',
          'name': 'Chicken Curry',
          'priceMinor': 1200,
          'sectionIds': <String>[],
          'productionArea': 'kitchen',
          'isAvailable': true,
          'isArchived': false,
          'showOnOrderFlow': true,
          'variants': <Object?>[],
          'modifierGroupIds': <String>[],
          'stockComponents': <Object?>[],
        },
      ],
      'tables': [
        {'id': 'table-7', 'label': 'Table 7', 'active': true},
      ],
      'staff': [
        {
          'staffId': 'staff-1',
          'displayName': 'Jamie',
          'roles': ['manager'],
        },
      ],
      'courses': [
        {'id': 'main', 'name': 'Main', 'sequence': 2},
      ],
    });
    view.installOrders([
      {
        'orderId': 'order-1',
        'tenantId': 'tenant-1',
        'venueId': 'venue-1',
        'tableId': 'table-7',
        'openedAtUtc': '2026-10-27T12:00:00.000Z',
        'isClosed': false,
        'lines': <Object?>[
          {
            'id': 'line-1',
            'productId': 'curry',
            'name': 'Chicken Curry',
            'quantity': 2,
            'unitPriceMinor': 1200,
            'productionArea': 'kitchen',
            'sent': true,
            'sentAtUtc': '2026-10-27T12:05:00.000Z',
            'details': ['NOTE: No chilli'],
          },
        ],
        'payments': <Object?>[],
      },
    ]);

    expect(view.courses.single.name, 'Main');
    expect(view.staff.single.name, 'Jamie');
    expect(view.orderFlowOrders, hasLength(1));
    final ticket = view.orderFlowOrders.single;
    expect(ticket.tableLabel, 'Table 7');
    expect(ticket.productionArea, ProductionArea.kitchen);
    expect(ticket.status, OrderFlowStatus.newOrder);
    expect(ticket.itemSummary, ['2 x Chicken Curry', '  NOTE: No chilli']);
    view.clear();
  });
}
