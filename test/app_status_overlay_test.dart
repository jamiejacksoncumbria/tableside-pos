import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';

void main() {
  test(
    'hub and command status overlays never occupy the same vertical slot',
    () {
      final offsets = appStatusOverlayOffsets(
        topInset: 24,
        showStaging: true,
        showHubIssue: true,
        showPending: true,
      );

      expect(offsets.hubTop, 66);
      expect(offsets.pendingTop, 124);
      expect(offsets.updatesTop, 182);
    },
  );

  test('unused status rows do not reserve screen space', () {
    final offsets = appStatusOverlayOffsets(
      topInset: 0,
      showStaging: false,
      showHubIssue: false,
      showPending: false,
    );

    expect(offsets.hubTop, 8);
    expect(offsets.pendingTop, 8);
    expect(offsets.updatesTop, 8);
  });
}
