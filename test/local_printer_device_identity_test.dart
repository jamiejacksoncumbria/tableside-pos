import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/features/printing/local_printer_device_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clonable legacy device ID is replaced by secure v2 identity', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    final identity = LocalPrinterDeviceIdentity();
    final physicalId = await identity.getOrCreate();
    final scopedId = await identity.deviceIdForScope(
      const VenueScope(tenantId: 'tenant-a', venueId: 'venue-a'),
    );

    expect(physicalId, matches(RegExp(r'^device-v2-[0-9a-f]{32}$')));
    expect(physicalId, isNot('device-cloned-from-another-installation'));
    expect(scopedId, startsWith('$physicalId-'));
  });
}
