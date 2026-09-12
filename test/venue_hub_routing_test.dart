import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_routing.dart';

void main() {
  test(
    'cloud-connected web is read-only while unreachable hub owns writes',
    () {
      expect(
        chooseVenueMutationRoute(
          const VenueHubRoutingInput(
            platform: VenueClientPlatform.web,
            cloudReachable: true,
            hubReachable: false,
            hubOwnsAuthority: true,
          ),
        ),
        VenueMutationRoute.readOnly,
      );
    },
  );

  test('native LAN clients write through authoritative hub', () {
    for (final platform in [
      VenueClientPlatform.android,
      VenueClientPlatform.ios,
      VenueClientPlatform.windows,
    ]) {
      expect(
        chooseVenueMutationRoute(
          VenueHubRoutingInput(
            platform: platform,
            cloudReachable: false,
            hubReachable: true,
            hubOwnsAuthority: true,
          ),
        ),
        VenueMutationRoute.venueHub,
      );
    }
  });

  test(
    'LAN web stays unavailable without cloud even when hub is reachable',
    () {
      expect(
        chooseVenueMutationRoute(
          const VenueHubRoutingInput(
            platform: VenueClientPlatform.web,
            cloudReachable: false,
            hubReachable: true,
            hubOwnsAuthority: true,
            webAppAvailableOffline: true,
          ),
        ),
        VenueMutationRoute.unavailable,
      );
    },
  );

  test('normal online operation routes to Firebase', () {
    expect(
      chooseVenueMutationRoute(
        const VenueHubRoutingInput(
          platform: VenueClientPlatform.windows,
          cloudReachable: true,
          hubReachable: false,
          hubOwnsAuthority: false,
        ),
      ),
      VenueMutationRoute.firebase,
    );
  });
}
