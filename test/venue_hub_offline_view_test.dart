import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/fulfilment/fulfilment_domain.dart';
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
}
