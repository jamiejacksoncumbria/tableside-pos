import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/order_flow/order_flow_timing.dart';

void main() {
  test('ticket age uses absolute time across local and UTC timestamps', () {
    final releasedAt = DateTime.utc(2026, 10, 28, 10, 0);
    final localNow = DateTime.parse('2026-10-28T12:05:00+02:00');

    expect(orderFlowElapsed(localNow, releasedAt), const Duration(minutes: 5));
  });

  test('future ticket age is clamped while the trusted clock corrects', () {
    final now = DateTime.utc(2026, 10, 28, 10, 0);
    final futureRelease = now.add(const Duration(seconds: 20));

    expect(orderFlowElapsed(now, futureRelease), Duration.zero);
  });
}
