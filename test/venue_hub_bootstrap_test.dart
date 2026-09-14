import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_bootstrap.dart';

void main() {
  test('parses an enabled hub only with its active public credential', () {
    final credential = {
      'credentialId': 'credential-a',
      'deviceId': 'device-a',
      'algorithm': 'Ed25519',
      'publicKeyBase64': base64UrlEncode(List<int>.filled(32, 7)),
    };
    final bootstrap = VenueHubBootstrap.fromJson({
      'enabled': true,
      'hubEpoch': 4,
      'hubDeviceId': 'device-a',
      'hubCredentialId': 'credential-a',
      'hubEndpoint': 'https://192.168.1.20:8443',
      'serverTimeMillis': 1789214400000,
      'credentials': [credential],
    });
    expect(bootstrap.enabled, isTrue);
    expect(bootstrap.hubEpoch, 4);
    expect(bootstrap.credentials, contains('credential-a'));
  });

  test('parses the canonical unpadded Ed25519 public key from Firebase', () {
    final encodedKey = base64UrlEncode(
      List<int>.generate(32, (index) => index),
    ).replaceAll('=', '');
    expect(encodedKey, hasLength(43));

    final bootstrap = VenueHubBootstrap.fromJson({
      'enabled': false,
      'hubEpoch': 0,
      'serverTimeMillis': 1789214400000,
      'credentials': [
        {
          'credentialId': 'credential-a',
          'deviceId': 'device-a',
          'algorithm': 'Ed25519',
          'publicKeyBase64': encodedKey,
        },
      ],
    });

    expect(
      bootstrap.credentials['credential-a']!.publicKey.bytes,
      hasLength(32),
    );
  });

  test('fails closed when enabled hub authority credential is absent', () {
    expect(
      () => VenueHubBootstrap.fromJson({
        'enabled': true,
        'hubEpoch': 4,
        'hubDeviceId': 'device-a',
        'hubCredentialId': 'credential-a',
        'serverTimeMillis': 1789214400000,
        'credentials': const [],
      }),
      throwsFormatException,
    );
  });
}
