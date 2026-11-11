import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/offline/venue_hub_bootstrap.dart';
import 'package:tableside_pos/offline/venue_hub_client_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'secure bootstrap rediscovers a hub after preferences are lost',
    () async {
      const scope = VenueScope(tenantId: 'tenant-a', venueId: 'venue-b');
      final publicKey = SimplePublicKey(
        List<int>.generate(32, (index) => index),
        type: KeyPairType.ed25519,
      );
      final bootstrap = VenueHubBootstrap(
        enabled: true,
        hubEpoch: 7,
        hubDeviceId: 'device-a',
        hubCredentialId: 'credential-a',
        endpoint: Uri.parse('https://192.168.1.20:8443'),
        serverTimeMillis: 1700000000000,
        credentials: {
          'credential-a': VenueHubPublicCredential(
            id: 'credential-a',
            deviceId: 'device-a',
            publicKey: publicKey,
          ),
        },
      );

      await VenueHubClientCache().saveBootstrap(scope, bootstrap);

      // Simulate Windows repairing a truncated shared_preferences.json to an
      // empty object while OS-protected installation data remains available.
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();

      final recoveredCache = VenueHubClientCache();
      expect(await recoveredCache.readCandidateScopes(), contains(scope));
      final recovered = await recoveredCache.readBootstrap(scope);
      expect(recovered, isNotNull);
      expect(recovered!.hubEpoch, 7);
      expect(recovered.hubDeviceId, 'device-a');
      expect(recovered.hubCredentialId, 'credential-a');
      expect(recovered.endpoint, Uri.parse('https://192.168.1.20:8443'));
      expect(recovered.credentials.keys, contains('credential-a'));
    },
  );
}
