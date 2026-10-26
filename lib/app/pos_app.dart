import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/app_theme_controller.dart';
import '../core/app_logger.dart';
import '../core/app_busy_state.dart';
import '../core/app_environment.dart';
import '../core/firebase_bootstrap.dart';
import '../core/firebase_runtime_config.dart';
import '../core/shorebird_update_host.dart';
import '../features/auth/auth_gate.dart';
import '../offline/venue_hub_remote_command_client.dart';
import '../offline/venue_hub_availability.dart';
import '../offline/venue_hub_offline_workspace.dart';
import 'home_shell.dart';

@visibleForTesting
({double hubTop, double pendingTop, double updatesTop})
appStatusOverlayOffsets({
  required double topInset,
  required bool showStaging,
  required bool showHubIssue,
  required bool showPending,
}) {
  final firstTop = topInset + (showStaging ? 42 : 8);
  final hubHeight = showHubIssue ? 58.0 : 0.0;
  final pendingHeight = showPending ? 58.0 : 0.0;
  return (
    hubTop: firstTop,
    pendingTop: firstTop + hubHeight,
    updatesTop: firstTop + hubHeight + pendingHeight,
  );
}

// MaterialApp's builder is above its Navigator in the element tree. The root
// key gives global connectivity notices a context owned by the Navigator
// overlay instead of attempting showDialog with the builder's invalid parent
// context.
final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'TableSide root navigator',
);

class TableSideCYApp extends ConsumerWidget {
  const TableSideCYApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      appThemeControllerProvider.select((selection) => selection.effectiveMode),
    );
    return MaterialApp(
      navigatorKey: _rootNavigatorKey,
      title: AppEnvironment.isStaging ? 'TableSideCY STAGING' : 'TableSideCY',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (context, child) => ValueListenableBuilder<int>(
        valueListenable: RemoteHubWaitState.pending,
        builder: (context, pending, _) => ValueListenableBuilder<String?>(
          valueListenable: VenueHubAvailability.issue,
          builder: (context, hubIssue, _) =>
              ValueListenableBuilder<VenueHubConnectionStatus>(
                valueListenable: VenueHubAvailability.status,
                builder: (context, hubStatus, _) => ValueListenableBuilder<int>(
                  valueListenable: AppBusyState.pending,
                  builder: (context, busy, _) {
                    final showStaging =
                        FirebaseRuntimeConfig.enabled &&
                        AppEnvironment.isStaging;
                    final topInset = MediaQuery.paddingOf(context).top;
                    final overlayOffsets = appStatusOverlayOffsets(
                      topInset: topInset,
                      showStaging: showStaging,
                      showHubIssue: hubIssue != null,
                      showPending: pending > 0,
                    );
                    return _HubOfflineDialogHost(
                      issue: hubIssue,
                      child: Stack(
                        children: [
                          ?child,
                          if (showStaging)
                            Positioned(
                              top: topInset + 4,
                              left: 12,
                              child: IgnorePointer(
                                child: Material(
                                  elevation: 12,
                                  color: const Color(0xffff9800),
                                  borderRadius: BorderRadius.circular(7),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    child: Text(
                                      'STAGING · TEST DATA ONLY',
                                      style: TextStyle(
                                        color: Colors.black,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (hubStatus.connectivity !=
                              VenueHubConnectivity.unknown)
                            Positioned(
                              top: topInset + 4,
                              right: 12,
                              child: _HubStatusBadge(status: hubStatus),
                            ),
                          if (pending > 0)
                            Positioned(
                              top: overlayOffsets.pendingTop,
                              left: 16,
                              right: 16,
                              child: Material(
                                elevation: 8,
                                color: Theme.of(
                                  context,
                                ).colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox.square(
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          pending == 1
                                              ? 'Waiting for venue hub…'
                                              : 'Waiting for venue hub… ($pending commands)',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (hubIssue != null)
                            Positioned(
                              top: overlayOffsets.hubTop,
                              left: 16,
                              right: 16,
                              child: Material(
                                elevation: 10,
                                color: Theme.of(
                                  context,
                                ).colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.hub_outlined),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'HUB UNAVAILABLE · LAN devices should join the venue Wi-Fi; remote devices need the hub internet heartbeat.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w900,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ShorebirdUpdateHost(top: overlayOffsets.updatesTop),
                          if (busy > 0) ...[
                            const Positioned.fill(
                              child: ModalBarrier(
                                dismissible: false,
                                color: Color(0x66000000),
                              ),
                            ),
                            Positioned.fill(
                              child: Center(
                                child: Card(
                                  elevation: 12,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 20,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(),
                                        const SizedBox(height: 14),
                                        Text(
                                          'Please wait…',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
        ),
      ),
      home: FirebaseRuntimeConfig.enabled
          ? const _FirebaseBootstrapGate()
          : const HomeShell(),
    );
  }
}

class _HubStatusBadge extends StatelessWidget {
  const _HubStatusBadge({required this.status});

  final VenueHubConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, foreground, icon) = switch (status.connectivity) {
      VenueHubConnectivity.online => (
        const Color(0xff2e7d32),
        Colors.white,
        Icons.cloud_done_rounded,
      ),
      VenueHubConnectivity.lanOnly => (
        const Color(0xfff9a825),
        Colors.black,
        Icons.wifi_rounded,
      ),
      VenueHubConnectivity.unavailable => (
        Theme.of(context).colorScheme.error,
        Theme.of(context).colorScheme.onError,
        Icons.cloud_off_rounded,
      ),
      VenueHubConnectivity.checking => (
        Theme.of(context).colorScheme.surfaceContainerHighest,
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.sync_rounded,
      ),
      VenueHubConnectivity.unknown => (
        Colors.transparent,
        Colors.transparent,
        Icons.help_outline_rounded,
      ),
    };
    return IgnorePointer(
      child: Material(
        elevation: 10,
        color: color,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 230),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    status.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Repeats the hub explanation at most once per minute while the fault remains
/// active. The banner stays visible after dismissing the dialog.
class _HubOfflineDialogHost extends StatefulWidget {
  const _HubOfflineDialogHost({required this.issue, required this.child});

  final String? issue;
  final Widget child;

  @override
  State<_HubOfflineDialogHost> createState() => _HubOfflineDialogHostState();
}

class _HubOfflineDialogHostState extends State<_HubOfflineDialogHost> {
  DateTime? _lastShown;
  bool _dialogOpen = false;
  DialogRoute<void>? _dialogRoute;

  @override
  void initState() {
    super.initState();
    _scheduleIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _HubOfflineDialogHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.issue != null && widget.issue == null) {
      // Never pop the root Navigator here. A payment or product sheet may be
      // above this dialog, and popping that unrelated route while its overlay
      // is rebuilding can corrupt inherited dependencies. Remove only the
      // exact hub dialog after the current widget frame is complete.
      final route = _dialogRoute;
      if (route != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final navigator = route.navigator;
          if (navigator != null) navigator.removeRoute(route);
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final messengerContext = _rootNavigatorKey.currentContext;
        if (!mounted || messengerContext == null) return;
        ScaffoldMessenger.maybeOf(messengerContext)?.showSnackBar(
          const SnackBar(
            content: Text('Venue hub is back online and ready.'),
            backgroundColor: Color(0xff2e7d32),
            duration: Duration(seconds: 3),
          ),
        );
      });
    }
    if (oldWidget.issue != widget.issue) _scheduleIfNeeded();
  }

  void _scheduleIfNeeded() {
    if (widget.issue == null || _dialogOpen) return;
    final now = DateTime.now();
    if (_lastShown != null && now.difference(_lastShown!).inSeconds < 60) {
      Future<void>.delayed(const Duration(minutes: 1), () {
        if (mounted) _scheduleIfNeeded();
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.issue == null || _dialogOpen) return;
      final dialogContext = _rootNavigatorKey.currentState?.overlay?.context;
      if (dialogContext == null) {
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          _scheduleIfNeeded,
        );
        return;
      }
      _dialogOpen = true;
      _lastShown = DateTime.now();
      final navigator = Navigator.of(dialogContext);
      final route = DialogRoute<void>(
        context: dialogContext,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.cloud_off_rounded),
          title: const Text('Venue hub is unavailable'),
          content: const Text(
            'This device cannot safely save orders until the hub responds. Devices on the venue network can use the local hub even without internet. Devices on another Wi-Fi or mobile data work through Firebase whenever the hub internet heartbeat is live.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      );
      _dialogRoute = route;
      await navigator.push<void>(route);
      await route.completed;
      if (identical(_dialogRoute, route)) _dialogRoute = null;
      _dialogOpen = false;
      if (mounted && widget.issue != null) _scheduleIfNeeded();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FirebaseBootstrapGate extends StatefulWidget {
  const _FirebaseBootstrapGate();

  @override
  State<_FirebaseBootstrapGate> createState() => _FirebaseBootstrapGateState();
}

class _FirebaseBootstrapGateState extends State<_FirebaseBootstrapGate> {
  late Future<_FirebaseStartupResult> _bootstrap = _initialize();

  Future<_FirebaseStartupResult> _initialize() async {
    try {
      AppLogger.info('Starting Firebase bootstrap.');
      await initializeFirebase().timeout(const Duration(seconds: 8));
      return const _FirebaseStartupResult.online();
    } on TimeoutException catch (error, stackTrace) {
      AppLogger.error('Firebase cold-start timeout', error, stackTrace);
      final offline = await VenueHubOfflineWorkspaceLoader().load();
      if (offline != null) {
        AppLogger.info(
          'Firebase is unavailable; opening the verified encrypted workspace '
          'for local hub venue=${offline.scope.venueId}.',
        );
        return _FirebaseStartupResult.offline(offline);
      }
      return _FirebaseStartupResult.failure(
        'Firebase did not respond and this installation is not the verified '
        'offline hub for a cached venue.',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Firebase startup', error, stackTrace);
      final offline = await VenueHubOfflineWorkspaceLoader().load();
      if (offline != null) return _FirebaseStartupResult.offline(offline);
      return _FirebaseStartupResult.failure('$error');
    }
  }

  void _retry() {
    setState(() => _bootstrap = _initialize());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_FirebaseStartupResult>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final result = snapshot.data;
        if (result == null || result.error != null) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_rounded, size: 42),
                    const SizedBox(height: 16),
                    Text(
                      'TableSideCY could not start its online services.\n\n'
                      '${result?.error ?? snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry connection'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (result.offlineWorkspace case final workspace?) {
          return OfflineHubWorkspace(
            workspace: workspace,
            onRetryOnline: _retry,
          );
        }
        return const FirebaseAuthGate();
      },
    );
  }
}

class _FirebaseStartupResult {
  const _FirebaseStartupResult.online() : offlineWorkspace = null, error = null;

  const _FirebaseStartupResult.offline(this.offlineWorkspace) : error = null;

  const _FirebaseStartupResult.failure(this.error) : offlineWorkspace = null;

  final VenueHubOfflineWorkspace? offlineWorkspace;
  final String? error;
}
