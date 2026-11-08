import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_realtime_client.dart';

void main() {
  test('future-skewed presence cannot keep a dead hub online', () {
    final now = DateTime.utc(2026, 11, 9, 12);

    expect(
      venueHubPresenceIsFresh(
        trustedNowUtc: now,
        lastReadyAtUtc: now.add(const Duration(hours: 2)),
      ),
      isFalse,
    );
    expect(
      venueHubPresenceIsFresh(
        trustedNowUtc: now,
        lastReadyAtUtc: now.subtract(const Duration(seconds: 10)),
      ),
      isTrue,
    );
    expect(
      venueHubPresenceIsFresh(
        trustedNowUtc: now,
        lastReadyAtUtc: now.subtract(const Duration(seconds: 16)),
      ),
      isFalse,
    );
  });
}
