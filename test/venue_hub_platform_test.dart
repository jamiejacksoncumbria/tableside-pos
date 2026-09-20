import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_platform.dart';

void main() {
  test('only Android and Windows native devices may host a venue hub', () {
    expect(
      venueHubHostingSupported(isWeb: false, platform: TargetPlatform.android),
      isTrue,
    );
    expect(
      venueHubHostingSupported(isWeb: false, platform: TargetPlatform.windows),
      isTrue,
    );
    expect(
      venueHubHostingSupported(isWeb: false, platform: TargetPlatform.iOS),
      isFalse,
    );
    expect(
      venueHubHostingSupported(isWeb: true, platform: TargetPlatform.android),
      isFalse,
    );
  });
}
