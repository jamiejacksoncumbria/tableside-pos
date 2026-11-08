import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_backup_monitor.dart';

void main() {
  test('backup lease expiry uses monotonic silence, not wall-clock time', () {
    var elapsedMicroseconds = 0;
    final tracker = VenueHubLeaseSilenceTracker(
      monotonicMicroseconds: () => elapsedMicroseconds,
    );

    // This timestamp may be ahead of the Android wall clock. Its absolute
    // value is irrelevant; only whether Firebase advances it matters.
    tracker.observe(4102444800000);
    elapsedMicroseconds = const Duration(seconds: 29).inMicroseconds;
    expect(tracker.isSilentFor(const Duration(seconds: 30)), isFalse);

    // A new primary lease resets the failover window.
    tracker.observe(4102444805000);
    elapsedMicroseconds = const Duration(seconds: 58).inMicroseconds;
    expect(tracker.isSilentFor(const Duration(seconds: 30)), isFalse);

    elapsedMicroseconds = const Duration(seconds: 60).inMicroseconds;
    expect(tracker.isSilentFor(const Duration(seconds: 30)), isTrue);
  });
}
