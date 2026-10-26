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
  });

  test('remote-only terminal still reports a cloud outage', () {
    VenueHubAvailability.markRemoteOffline(
      lanSessionAvailable: false,
      detail: 'Cloud heartbeat is unavailable.',
    );

    expect(
      VenueHubAvailability.issue.value,
      'Cloud heartbeat is unavailable.',
    );
  });
}
