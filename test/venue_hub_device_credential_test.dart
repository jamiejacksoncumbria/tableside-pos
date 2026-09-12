import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_device_credential.dart';

void main() {
  test('credential is stable per device and isolated by venue', () async {
    final secrets = _MemorySecrets();
    final store = VenueHubDeviceCredentialStore(secrets: secrets);
    final first = await store.getOrCreate(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
    );
    final again = await store.getOrCreate(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
    );
    final otherVenue = await store.getOrCreate(
      tenantId: 'tenant-a',
      venueId: 'venue-b',
      deviceId: 'device-a',
    );

    expect(again.credentialId, first.credentialId);
    expect(again.publicKeyBase64, first.publicKeyBase64);
    expect(otherVenue.credentialId, isNot(first.credentialId));
    expect(secrets.values, hasLength(2));
  });

  test('local revocation rotates the signing identity', () async {
    final secrets = _MemorySecrets();
    final store = VenueHubDeviceCredentialStore(secrets: secrets);
    final before = await store.getOrCreate(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
    );
    await store.revokeLocal(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
    );
    final after = await store.getOrCreate(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
    );
    expect(after.credentialId, isNot(before.credentialId));
  });
}

class _MemorySecrets implements VenueHubSecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
