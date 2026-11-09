import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_bootstrap.dart';

void main() {
  test('each hub device resolves only its own saved endpoint', () {
    final bootstrap = VenueHubBootstrap(
      enabled: true,
      hubEpoch: 4,
      hubDeviceId: 'primary-device',
      hubCredentialId: 'primary-key',
      endpoint: Uri.parse('https://192.168.1.20:8443'),
      backupDeviceId: 'backup-device',
      backupCredentialId: 'backup-key',
      backupEndpoint: Uri.parse('https://192.168.1.21:8443'),
      credentials: const {},
      serverTimeMillis: 1,
    );

    expect(
      bootstrap.endpointForHostDevice('primary-device')?.host,
      '192.168.1.20',
    );
    expect(
      bootstrap.endpointForHostDevice('backup-device')?.host,
      '192.168.1.21',
    );
    expect(bootstrap.endpointForHostDevice('former-primary'), isNull);
    expect(bootstrap.endpointForHostDevice(null), isNull);
  });

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

  test('parses a distinct passive backup authority', () {
    final credentials = [
      for (final entry in [('primary', 3), ('backup', 9)])
        {
          'credentialId': '${entry.$1}-credential',
          'deviceId': '${entry.$1}-device',
          'algorithm': 'Ed25519',
          'publicKeyBase64': base64UrlEncode(List<int>.filled(32, entry.$2)),
        },
    ];
    final bootstrap = VenueHubBootstrap.fromJson({
      'enabled': true,
      'hubEpoch': 7,
      'hubDeviceId': 'primary-device',
      'hubCredentialId': 'primary-credential',
      'hubEndpoint': 'https://192.168.1.20:8443',
      'backupDeviceId': 'backup-device',
      'backupCredentialId': 'backup-credential',
      'backupEndpoint': 'https://192.168.1.21:8443',
      'serverTimeMillis': 1789214400000,
      'credentials': credentials,
    });

    expect(bootstrap.backupDeviceId, 'backup-device');
    expect(bootstrap.backupCredentialId, 'backup-credential');
    expect(bootstrap.backupEndpoint?.host, '192.168.1.21');
  });

  test('fails closed when a backup credential is absent', () {
    expect(
      () => VenueHubBootstrap.fromJson({
        'enabled': false,
        'hubEpoch': 2,
        'backupDeviceId': 'backup-device',
        'backupCredentialId': 'missing-credential',
        'backupEndpoint': 'https://192.168.1.21:8443',
        'serverTimeMillis': 1789214400000,
        'credentials': const [],
      }),
      throwsFormatException,
    );
  });
}
