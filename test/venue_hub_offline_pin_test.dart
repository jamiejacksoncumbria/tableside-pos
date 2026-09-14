import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_offline_pin.dart';
import 'package:tableside_pos/offline/venue_hub_staff_sessions.dart';

void main() {
  test('reports a missing legacy offline verifier distinctly', () async {
    final sessions = VenueHubStaffSessionAuthority(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
    );
    final pins = VenueHubOfflinePinAuthority(
      sessions: sessions,
      tenantId: 'tenant-a',
      venueId: 'venue-a',
    );

    await expectLater(
      pins.verify(staffId: 'legacy-staff', pin: '123456'),
      throwsA(
        isA<VenueHubOfflinePinException>().having(
          (error) => error.code,
          'code',
          'offline_verifier_unavailable',
        ),
      ),
    );
  });
}
