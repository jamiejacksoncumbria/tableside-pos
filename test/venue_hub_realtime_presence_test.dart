import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_realtime_presence.dart';

void main() {
  const deviceId = 'device-v2-a';
  const hubEpoch = 7;

  test('missing realtime data is not treated as authority revocation', () {
    expect(
      parseVenueHubAuthority(null, deviceId: deviceId, hubEpoch: hubEpoch),
      isNull,
    );
    expect(
      parseVenueHubAuthority(
        const <String, Object?>{},
        deviceId: deviceId,
        hubEpoch: hubEpoch,
      ),
      isNull,
    );
  });

  test('complete matching authority keeps the hub active', () {
    expect(
      parseVenueHubAuthority(
        const <String, Object?>{
          'enabled': true,
          'deviceId': deviceId,
          'hubEpoch': hubEpoch,
        },
        deviceId: deviceId,
        hubEpoch: hubEpoch,
      ),
      isTrue,
    );
  });

  test('explicit disable or replacement revokes the old hub', () {
    expect(
      parseVenueHubAuthority(
        const <String, Object?>{
          'enabled': false,
          'deviceId': deviceId,
          'hubEpoch': hubEpoch,
        },
        deviceId: deviceId,
        hubEpoch: hubEpoch,
      ),
      isFalse,
    );
    expect(
      parseVenueHubAuthority(
        const <String, Object?>{
          'enabled': true,
          'deviceId': 'replacement-device',
          'hubEpoch': hubEpoch + 1,
        },
        deviceId: deviceId,
        hubEpoch: hubEpoch,
      ),
      isFalse,
    );
  });
}
