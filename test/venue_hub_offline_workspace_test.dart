import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/offline/venue_hub_offline_workspace.dart';

void main() {
  test('restores venue identity and operating settings from hub snapshot', () {
    const scope = VenueScope(tenantId: 'tenant-a', venueId: 'venue-b');
    final workspace = venueHubOfflineWorkspaceFromSnapshot(scope, {
      'tenantName': 'TableSide Hospitality',
      'venueName': 'Spice Garden',
      'currencyCode': 'try',
      'venueTimeZone': 'Europe/Istanbul',
      'venueCountry': 'North Cyprus',
      'tenantAddress': 'Head office',
      'tenantPhoneNumbers': ['111'],
      'venueAddress': 'Venue road',
      'venuePhoneNumbers': ['222'],
      'receiptFooter': 'Thank you',
      'collectionEnabled': true,
      'deliveryEnabled': true,
      'courseControlEnabled': true,
      'businessDayCutoffMinutes': 300,
      'deliveryLocations': {
        'Kyrenia': ['Centre', 'Karakum'],
      },
    });

    expect(workspace.scope, scope);
    expect(workspace.profile.displayName, 'TableSide Hospitality');
    expect(workspace.profile.currencyCode, 'TRY');
    expect(workspace.profile.phoneNumbers, ['111']);
    expect(workspace.venue.name, 'Spice Garden');
    expect(workspace.venue.timeZone, 'Europe/Istanbul');
    expect(workspace.venue.address, 'Venue road');
    expect(workspace.venue.collectionEnabled, isTrue);
    expect(workspace.venue.deliveryEnabled, isTrue);
    expect(workspace.venue.courseControlEnabled, isTrue);
    expect(workspace.venue.businessDayCutoffMinutes, 300);
    expect(workspace.venue.deliveryLocations['Kyrenia'], ['Centre', 'Karakum']);
  });
}
