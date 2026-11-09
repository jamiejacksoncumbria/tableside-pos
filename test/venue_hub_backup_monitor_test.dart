import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
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

  test(
    'manual takeover cannot run until manager confirmation is requested',
    () async {
      final coordinator = VenueHubManualTakeoverCoordinator.instance;
      coordinator.unbind();
      var calls = 0;
      coordinator.bind((pin, reason) async {
        calls++;
        expect(pin, '123456');
        expect(reason, 'Primary has lost power');
      });

      await expectLater(
        coordinator.confirm(managerPin: '123456', reason: 'No request'),
        throwsStateError,
      );
      expect(calls, 0);

      const scope = VenueScope(tenantId: 'tenant-a', venueId: 'venue-a');
      coordinator.requireConfirmation(
        VenueHubManualTakeoverRequest(
          scope: scope,
          primaryDeviceId: 'primary-a',
          detectedAt: DateTime.utc(2026),
        ),
      );
      await coordinator.confirm(
        managerPin: '123456',
        reason: 'Primary has lost power',
      );
      expect(calls, 1);
      coordinator.unbind();
    },
  );
}
