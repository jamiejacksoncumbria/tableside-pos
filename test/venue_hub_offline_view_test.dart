import 'package:flutter_test/flutter_test.dart';
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
}
