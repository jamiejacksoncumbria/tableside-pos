import 'dart:convert';

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

  test('accepts unpadded Base64URL verifiers produced by Node', () async {
    final sessions = VenueHubStaffSessionAuthority(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
    );
    final pins = VenueHubOfflinePinAuthority(
      sessions: sessions,
      tenantId: 'tenant-a',
      venueId: 'venue-a',
    );
    final salt = base64UrlEncode(
      List<int>.generate(16, (index) => index),
    ).replaceAll('=', '');
    final hash = base64UrlEncode(
      List<int>.generate(32, (index) => index),
    ).replaceAll('=', '');

    await pins.installSnapshot(<String, Object?>{
      'version': 1,
      'staff': <Object?>[
        <String, Object?>{
          'staffId': 'staff-a',
          'displayName': 'Staff A',
          'permissions': <String>['order.create'],
          'pinVersion': 1,
          'membershipVersion': 1,
          'offlinePinAlgorithm': 'PBKDF2-HMAC-SHA256',
          'offlinePinSaltEncoding': 'base64url-bytes-v1',
          'offlinePinIterations': 600000,
          'offlinePinSalt': salt,
          'offlinePinHash': hash,
        },
      ],
    });

    expect(pins.staff.single.staffId, 'staff-a');
  });
}
