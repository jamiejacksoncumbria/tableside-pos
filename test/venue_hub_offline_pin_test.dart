import 'dart:convert';

import 'package:cryptography/cryptography.dart';
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

  test('derives the same PBKDF2 verifier as Node crypto', () async {
    final salt = base64Url.decode(
      base64Url.normalize('AAECAwQFBgcICQoLDA0ODw'),
    );
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 600000,
      bits: 256,
    ).deriveKeyFromPassword(password: '123456', nonce: salt);

    expect(
      base64UrlEncode(await key.extractBytes()).replaceAll('=', ''),
      'k5IuOfF746yC7knkG2ibL4Jf_LmxjGRAY1DJK0-jxZw',
    );
  });
}
