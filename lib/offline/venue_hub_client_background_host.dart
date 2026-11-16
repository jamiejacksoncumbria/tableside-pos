import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_logger.dart';
import 'venue_hub_platform.dart';

/// Keeps an Android POS terminal reachable while the screen is locked.
///
/// Hub and backup-hub modes use the same native foreground service with a
/// stronger authority mode. Native `stopClient` is ownership-aware, so this
/// host can never stop a service after the device has been promoted to a hub.
class VenueHubClientBackgroundHost extends StatefulWidget {
  const VenueHubClientBackgroundHost({super.key});

  @override
  State<VenueHubClientBackgroundHost> createState() =>
      _VenueHubClientBackgroundHostState();
}

class _VenueHubClientBackgroundHostState
    extends State<VenueHubClientBackgroundHost> {
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await AndroidVenueHubService.startClient();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Keep Android terminal connected in background',
        error,
        stackTrace,
      );
    }
  }

  @override
  void dispose() {
    unawaited(AndroidVenueHubService.stopClient());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
