import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/production_command_repository.dart';
import '../features/notifications/notification_centre.dart';
import 'app_logger.dart';
import 'tenant_scope.dart';
import 'trusted_clock.dart';

class TrustedClockHost extends ConsumerStatefulWidget {
  const TrustedClockHost({super.key});

  @override
  ConsumerState<TrustedClockHost> createState() => _TrustedClockHostState();
}

class _TrustedClockHostState extends ConsumerState<TrustedClockHost> {
  Timer? _refreshTimer;
  VenueScope? _scope;
  bool _synchronising = false;
  bool _warnedForCurrentSkew = false;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope != _scope) scheduleMicrotask(() => _configure(scope));
    return const SizedBox.shrink();
  }

  void _configure(VenueScope? scope) {
    if (!mounted || scope == _scope) return;
    _refreshTimer?.cancel();
    _scope = scope;
    _warnedForCurrentSkew = false;
    if (scope == null) return;
    unawaited(_synchronise(scope));
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_synchronise(scope)),
    );
  }

  Future<void> _synchronise(VenueScope scope) async {
    if (_synchronising || !mounted || _scope != scope) return;
    _synchronising = true;
    try {
      final repository = ref.read(productionCommandRepositoryProvider);
      final sample = await TrustedClock.instance.synchroniseFirebase(
        () => repository.fetchTrustedTime(scope: scope),
      );
      AppLogger.info(
        'Trusted clock synchronised: authority=firebase, '
        'skewMs=${sample.offset.inMilliseconds}, '
        'roundTripMs=${sample.roundTrip.inMilliseconds}.',
      );
      if (sample.hasMaterialSkew && !_warnedForCurrentSkew && mounted) {
        _warnedForCurrentSkew = true;
        showAppNotification(
          context,
          ref: ref,
          title: 'Device clock needs attention',
          message:
              'This device differs from trusted venue time by more than two minutes. Saved sales remain server-timed, but check its date, time and timezone.',
          level: AppNotificationLevel.warning,
        );
      } else if (!sample.hasMaterialSkew) {
        _warnedForCurrentSkew = false;
      }
    } on Object catch (error, stackTrace) {
      // Failure to refresh must not replace the last good sample. During an
      // outage the venue-hub client will install its own signed time sample.
      AppLogger.error('Synchronise trusted clock', error, stackTrace);
    } finally {
      _synchronising = false;
    }
  }
}
