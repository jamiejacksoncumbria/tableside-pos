part of '../home_shell.dart';

class _VenueHubRealtimeStatusHost extends ConsumerStatefulWidget {
  const _VenueHubRealtimeStatusHost();

  @override
  ConsumerState<_VenueHubRealtimeStatusHost> createState() =>
      _VenueHubRealtimeStatusHostState();
}

class _VenueHubRealtimeStatusHostState
    extends ConsumerState<_VenueHubRealtimeStatusHost> {
  Timer? _retryTimer;
  String? _configurationKey;
  bool _configuring = false;

  void _scheduleConfiguration() {
    if (!kIsWeb || _configuring) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_configure());
    });
  }

  Future<void> _configure() async {
    if (_configuring || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    final session = ref.read(activeStaffPinSessionProvider);
    if (scope == null || session == null) return;
    final bootstrap = VenueHubClientRegistry.instance.bootstrapFor(scope);
    if (bootstrap == null) {
      _scheduleRetry(const Duration(milliseconds: 500));
      return;
    }
    if (!bootstrap.enabled) {
      _configurationKey = '${scope.tenantId}/${scope.venueId}/cloud-only';
      VenueHubAvailability.markCloudOnly();
      return;
    }
    final key =
        '${scope.tenantId}/${scope.venueId}/${bootstrap.hubEpoch}/${session.sessionId}';
    if (_configurationKey == key &&
        VenueHubRealtimeClient.instance.isReadyFor(scope, bootstrap.hubEpoch)) {
      return;
    }
    _configuring = true;
    _retryTimer?.cancel();
    if (VenueHubAvailability.status.value.connectivity ==
        VenueHubConnectivity.unknown) {
      VenueHubAvailability.markChecking('Connecting to venue hub presence…');
    }
    try {
      await VenueHubRealtimeClient.instance.ensureConfigured(
        scope: scope,
        hubEpoch: bootstrap.hubEpoch,
        repository: ProductionCommandRepository(),
      );
      _configurationKey = key;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Start realtime venue hub status for web workspace',
        error,
        stackTrace,
      );
      VenueHubAvailability.markOffline(
        'The venue hub status channel could not connect. Orders remain blocked until it reconnects.',
      );
      _scheduleRetry(const Duration(seconds: 10));
    } finally {
      _configuring = false;
    }
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _scheduleConfiguration);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeVenueScopeProvider);
    ref.watch(activeStaffPinSessionProvider);
    _scheduleConfiguration();
    return const SizedBox.shrink();
  }
}

/// Makes a failed primary hub visible to an already-unlocked manager on every
/// workspace screen. This is only navigation into the existing secured flow:
/// authority still transfers exclusively after a fresh manager PIN, reason,
/// acknowledgement, server-side lease check and audit event on the dedicated
/// venue-hub settings page.
class _VenueHubTakeoverPromptHost extends ConsumerStatefulWidget {
  const _VenueHubTakeoverPromptHost();

  @override
  ConsumerState<_VenueHubTakeoverPromptHost> createState() =>
      _VenueHubTakeoverPromptHostState();
}

class _VenueHubTakeoverPromptHostState
    extends ConsumerState<_VenueHubTakeoverPromptHost> {
  String? _lastPromptKey;
  bool _promptScheduled = false;
  bool _promptOpen = false;

  void _schedulePrompt(
    VenueHubManualTakeoverRequest request,
    VenueScope activeScope,
  ) {
    final key =
        '${request.scope.tenantId}/${request.scope.venueId}/'
        '${request.primaryDeviceId}/${request.detectedAt.microsecondsSinceEpoch}';
    if (_lastPromptKey == key || _promptScheduled || _promptOpen) return;
    _promptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _promptScheduled = false;
      if (!mounted) return;
      final current = VenueHubManualTakeoverCoordinator.instance.pending.value;
      final session = ref.read(activeStaffPinSessionProvider);
      final isManager =
          session?.roles.any((role) {
            final normalized = role.trim().toLowerCase();
            return normalized == 'owner' || normalized == 'manager';
          }) ??
          false;
      if (current != request || current?.scope != activeScope || !isManager) {
        return;
      }
      _lastPromptKey = key;
      _promptOpen = true;
      final review = await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Primary venue hub is unavailable'),
          content: const SingleChildScrollView(
            child: Text(
              'This device is the configured backup and the primary hub has '
              'stopped renewing its authority lease. Orders remain blocked. '
              'Would you like to review the manager-authorised takeover now?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Review takeover'),
            ),
          ],
        ),
      );
      _promptOpen = false;
      if (!mounted || review != true) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VenueOfflineHubPage(scope: activeScope),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeStaffPinSessionProvider);
    final activeScope = ref.watch(activeVenueScopeProvider);
    final isManager =
        session?.roles.any((role) {
          final normalized = role.trim().toLowerCase();
          return normalized == 'owner' || normalized == 'manager';
        }) ??
        false;
    // The takeover request is process-local operational state, not Riverpod
    // application data. Listen to its ValueNotifier explicitly so the prompt
    // appears immediately even if no unrelated widget/provider rebuild occurs.
    return ValueListenableBuilder<VenueHubManualTakeoverRequest?>(
      valueListenable: VenueHubManualTakeoverCoordinator.instance.pending,
      builder: (context, request, _) {
        if (request == null) {
          _lastPromptKey = null;
        } else if (isManager &&
            activeScope != null &&
            request.scope == activeScope) {
          _schedulePrompt(request, activeScope);
        }
        return const SizedBox.shrink();
      },
    );
  }
}

/// Keeps device enrolment and certificate failures in the manager-visible
/// notification centre. Background retries are deduplicated, and successful
/// hub recovery removes the alert automatically.
class _VenueHubAccessNotificationHost extends ConsumerStatefulWidget {
  const _VenueHubAccessNotificationHost();

  @override
  ConsumerState<_VenueHubAccessNotificationHost> createState() =>
      _VenueHubAccessNotificationHostState();
}

class _VenueHubAccessNotificationHostState
    extends ConsumerState<_VenueHubAccessNotificationHost> {
  static const _notificationKey = 'venue-hub-device-authorisation';

  @override
  void initState() {
    super.initState();
    VenueHubAvailability.issue.addListener(_scheduleHandle);
    _scheduleHandle();
  }

  void _scheduleHandle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final issue = VenueHubAvailability.issue.value;
      final controller = ref.read(appNotificationsProvider.notifier);
      if (issue == null) {
        controller.resolve(_notificationKey);
        return;
      }
      final presentation = venueHubIssuePresentation(issue);
      if (!presentation.requiresManagerAttention) {
        controller.resolve(_notificationKey);
        return;
      }
      controller.add(
        title: presentation.title,
        message: presentation.message,
        level: AppNotificationLevel.error,
        retentionSeconds: 60,
        deduplicationKey: _notificationKey,
        requiresAttention: true,
      );
    });
  }

  @override
  void dispose() {
    VenueHubAvailability.issue.removeListener(_scheduleHandle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Promotes a durable hub/cloud conflict into the manager-visible notification
/// tray. The warning remains until synchronization recovers or a staff member
/// deliberately dismisses it; routine temporary connectivity failures do not
/// create a permanent alarm.
class _VenueHubSynchronizationNotificationHost extends ConsumerStatefulWidget {
  const _VenueHubSynchronizationNotificationHost();

  @override
  ConsumerState<_VenueHubSynchronizationNotificationHost> createState() =>
      _VenueHubSynchronizationNotificationHostState();
}

class _VenueHubSynchronizationNotificationHostState
    extends ConsumerState<_VenueHubSynchronizationNotificationHost> {
  static const _notificationKey = 'venue-hub-cloud-sync-conflict';
  StreamSubscription<VenueHubRuntimeStatus>? _subscription;

  @override
  void initState() {
    super.initState();
    _scheduleHandle(VenueHubRuntime.instance.status);
    _subscription = VenueHubRuntime.instance.statuses.listen(_scheduleHandle);
  }

  /// Riverpod deliberately rejects provider mutations while Flutter is
  /// mounting or rebuilding the tree. Runtime status may already be degraded
  /// when this host first appears after PIN entry, so always promote it after
  /// the current frame rather than writing from [initState].
  void _scheduleHandle(VenueHubRuntimeStatus status) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handle(status);
    });
  }

  void _handle(VenueHubRuntimeStatus status) {
    if (!mounted) return;
    final message = status.message ?? '';
    final requiresAdministrator = message.contains(
      'Contact the system administrator',
    );
    final controller = ref.read(appNotificationsProvider.notifier);
    if (!requiresAdministrator) {
      controller.resolve(_notificationKey);
      return;
    }
    controller.add(
      title: 'Venue hub data needs administrator attention',
      message: '${status.pendingEvents} cloud event(s) are pending. $message',
      level: AppNotificationLevel.error,
      retentionSeconds: 60,
      deduplicationKey: _notificationKey,
      requiresAttention: true,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
