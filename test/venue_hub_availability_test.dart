import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_availability.dart';

void main() {
  tearDown(VenueHubAvailability.reset);

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

  test('device enrolment failures require visible manager attention', () {
    const issue =
        'This device is not enrolled with the venue hub. Orders are blocked.';
    final presentation = venueHubIssuePresentation(issue);

    expect(isVenueHubDeviceAuthorizationIssue(issue), isTrue);
    expect(presentation.requiresManagerAttention, isTrue);
    expect(presentation.title, contains('not authorised'));
    expect(presentation.message, contains('Venue offline hub'));
    expect(presentation.bannerLabel, contains('ORDERS BLOCKED'));
  });

  test('missing certificate is explained without exposing raw details', () {
    const issue =
        'This device is enrolled but has no pinned venue certificate.';
    final presentation = venueHubIssuePresentation(issue);

    expect(presentation.requiresManagerAttention, isTrue);
    expect(presentation.title, contains('certificate'));
    expect(presentation.message, contains('private key'));
  });

  test('ordinary network failure is not misclassified as unauthorised', () {
    const issue = 'The venue hub is offline.';
    final presentation = venueHubIssuePresentation(issue);

    expect(isVenueHubDeviceAuthorizationIssue(issue), isFalse);
    expect(presentation.requiresManagerAttention, isFalse);
    expect(presentation.title, 'Venue hub is unavailable');
  });

  test('a heartbeat cannot hide an unauthorised device', () {
    VenueHubAvailability.markOffline(
      'This device is not enrolled with the venue hub. Orders are blocked.',
    );

    VenueHubAvailability.markOnline();

    expect(VenueHubAvailability.hasDeviceAuthorizationIssue, isTrue);
    expect(VenueHubAvailability.canProcessOrders, isFalse);
  });

  test('validated enrolment explicitly clears the security block', () {
    VenueHubAvailability.markOffline(
      'This device has no pinned venue certificate. Orders are blocked.',
    );

    VenueHubAvailability.clearDeviceAuthorizationIssue();

    expect(VenueHubAvailability.issue.value, isNull);
    expect(
      VenueHubAvailability.status.value.connectivity,
      VenueHubConnectivity.checking,
    );
  });
}
