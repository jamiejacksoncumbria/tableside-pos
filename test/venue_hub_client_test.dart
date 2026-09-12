import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_client.dart';
import 'package:tableside_pos/offline/venue_hub_device_credential.dart';

void main() {
  test('sends a signed event and accepts durable acknowledgement', () async {
    final credential =
        await VenueHubDeviceCredentialStore(
          secrets: _MemorySecrets(),
        ).getOrCreate(
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          deviceId: 'device-a',
        );
    late Map<String, dynamic> sent;
    final client = VenueHubClient(
      configuration: VenueHubClientConfiguration(
        endpoint: Uri.parse('https://hub.example.test:8443'),
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'device-a',
        staffId: 'staff-a',
        staffSessionId: 'session-a',
        staffSessionToken: '01234567890123456789012345678901',
        hubEpoch: 2,
        credential: credential,
      ),
      httpClient: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'accepted': true,
            'eventId': 'evt-a',
            'sequence': 4,
            'eventHash': 'hash-a',
            'committedAtUtc': '2026-09-12T12:00:00.000Z',
          }),
          201,
        );
      }),
    );
    final acknowledgement = await client.sendEvent(
      eventType: 'order.opened',
      payload: const {'orderId': 'order-a'},
    );
    expect(sent['body']['eventType'], 'order.opened');
    expect(sent['envelope']['signature'], isNotEmpty);
    expect(acknowledgement.sequence, 4);
  });

  test('refuses an unencrypted hub endpoint', () async {
    final credential =
        await VenueHubDeviceCredentialStore(
          secrets: _MemorySecrets(),
        ).getOrCreate(
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          deviceId: 'device-a',
        );
    expect(
      () => VenueHubClient(
        configuration: VenueHubClientConfiguration(
          endpoint: Uri.parse('http://192.168.1.10:8443'),
          tenantId: 'tenant-a',
          venueId: 'venue-a',
          deviceId: 'device-a',
          staffId: 'staff-a',
          staffSessionId: 'session-a',
          staffSessionToken: '01234567890123456789012345678901',
          hubEpoch: 2,
          credential: credential,
        ),
      ),
      throwsArgumentError,
    );
  });
}

class _MemorySecrets implements VenueHubSecretStore {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
