import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_availability.dart';

void main() {
  tearDown(VenueHubAvailability.markOnline);

  test('cloud outage does not hide a healthy LAN hub session', () {
    VenueHubAvailability.markRemoteOffline(
      lanSessionAvailable: true,
      detail: 'Cloud heartbeat is unavailable.',
    );

    expect(VenueHubAvailability.issue.value, isNull);
    expect(
      VenueHubAvailability.status.value.connectivity,
      VenueHubConnectivity.lanOnly,
    );
    expect(VenueHubAvailability.canProcessOrders, isTrue);
  });

  test('remote-only terminal still reports a cloud outage', () {
    VenueHubAvailability.markRemoteOffline(
      lanSessionAvailable: false,
      detail: 'Cloud heartbeat is unavailable.',
    );

    expect(VenueHubAvailability.issue.value, 'Cloud heartbeat is unavailable.');
    expect(
      VenueHubAvailability.status.value.connectivity,
      VenueHubConnectivity.unavailable,
    );
    expect(VenueHubAvailability.canProcessOrders, isFalse);
  });

  test('recovery publishes a positive internet status', () {
    VenueHubAvailability.markOffline('Stopped');
    VenueHubAvailability.markOnline();

    expect(VenueHubAvailability.issue.value, isNull);
    expect(
      VenueHubAvailability.status.value.connectivity,
      VenueHubConnectivity.online,
    );
    expect(VenueHubAvailability.status.value.shortLabel, contains('online'));
  });
}
