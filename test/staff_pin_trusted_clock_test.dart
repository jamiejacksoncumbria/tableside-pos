import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/trusted_clock.dart';
import 'package:tableside_pos/features/auth/staff_pin_gate.dart';

void main() {
  test('offline PIN session expiry uses the trusted hub clock', () {
    final deviceNow = DateTime.now().toUtc();
    final trustedNow = deviceNow.subtract(const Duration(days: 2));
    TrustedClock.instance.acceptHubSample(
      hubTimeMillis: trustedNow.millisecondsSinceEpoch,
      requestStartedUtc: deviceNow,
      responseReceivedUtc: deviceNow,
      hubEpoch: 1,
    );

    final expiresAt = trustedNow.add(const Duration(minutes: 30));
    expect(expiresAt.isAfter(deviceNow), isFalse);
    expect(isStaffPinSessionCurrent(expiresAt), isTrue);
  });
}
