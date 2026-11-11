import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/app_theme_controller.dart';
import '../../core/tenant_scope.dart';
import '../../core/order_flow_display_mode.dart';
import '../../core/staff_pin_session_store.dart';
import '../../core/training_mode.dart';
import '../../core/trusted_clock.dart';
import '../../data/production_command_repository.dart';
import '../../features/printing/local_printer_device_identity.dart';
import '../../offline/venue_hub_bootstrap.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_client_cache.dart';
import '../../offline/venue_hub_client.dart';
import '../../offline/venue_hub_device_credential.dart';
import '../../offline/venue_hub_runtime.dart';
import '../../offline/venue_hub_realtime_client.dart';

part 'widgets/staff_pin_widgets.dart';

User? get _currentFirebaseUser =>
    Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser;

/// PIN sessions issued by the offline hub use its trusted clock authority.
/// Comparing them with the raw device clock can immediately expire a valid
/// session when a till's system clock differs from the last trusted sample.
@visibleForTesting
bool isStaffPinSessionCurrent(DateTime expiresAt) =>
    expiresAt.toUtc().isAfter(TrustedClock.instance.nowUtc());

Duration _staffPinSessionRemaining(DateTime expiresAt) =>
    expiresAt.toUtc().difference(TrustedClock.instance.nowUtc());

/// Internal control flow used to avoid touching Firebase during a verified
/// native hub cold start. It is never shown to the operator.
class _UseCachedHubBootstrap implements Exception {
  const _UseCachedHubBootstrap();
}

final activeStaffPinSessionProvider =
    NotifierProvider<ActiveStaffPinSessionController, StaffPinVerification?>(
      ActiveStaffPinSessionController.new,
    );

final posCategoryViewPreferenceProvider =
    NotifierProvider<PosCategoryViewPreferenceController, String>(
      PosCategoryViewPreferenceController.new,
    );

final posProductSortPreferenceProvider =
    NotifierProvider<PosProductSortPreferenceController, String>(
      PosProductSortPreferenceController.new,
    );

class PosCategoryViewPreferenceController extends Notifier<String> {
  @override
  String build() => 'bars';

  void apply(String preference) {
    state = preference == 'tiles' ? 'tiles' : 'bars';
  }
}

class PosProductSortPreferenceController extends Notifier<String> {
  @override
  String build() => 'alphabetical';

  void apply(String preference) {
    state = switch (preference) {
      'priceAsc' || 'priceDesc' => preference,
      _ => 'alphabetical',
    };
  }
}

class ActiveStaffPinSessionController extends Notifier<StaffPinVerification?> {
  @override
  StaffPinVerification? build() => null;

  void unlock(StaffPinVerification session, VenueScope scope) {
    StaffPinSessionStore.current = StaffPinSessionCredentials(
      sessionId: session.sessionId,
      sessionToken: session.sessionToken,
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      deviceId: session.deviceId,
    );
    state = session;
    ref
        .read(appThemeControllerProvider.notifier)
        .applyUserPreference(session.themeModePreference);
    ref
        .read(posCategoryViewPreferenceProvider.notifier)
        .apply(session.posCategoryViewPreference);
    ref
        .read(posProductSortPreferenceProvider.notifier)
        .apply(session.posProductSortPreference);
  }

  void lock() {
    StaffPinSessionStore.current = null;
    VenueHubClientRegistry.instance.clear();
    // The realtime custom token is staff-scoped. Drop it whenever the PIN
    // session locks so the next staff member cannot inherit the prior staff
    // member's command-status access.
    unawaited(VenueHubRealtimeClient.instance.clear());
    state = null;
    ref.read(trainingModeProvider.notifier).clear();
    ref.read(appThemeControllerProvider.notifier).clearUserPreference();
    ref.read(posCategoryViewPreferenceProvider.notifier).apply('bars');
    ref.read(posProductSortPreferenceProvider.notifier).apply('alphabetical');
  }

  void extendUntil(DateTime expiresAt) {
    final session = state;
    if (session == null || !expiresAt.isAfter(session.expiresAt)) return;
    state = session.copyWith(expiresAt: expiresAt);
  }

  /// Re-synchronises the process-memory credentials after hot reload or a
  /// protected child route rebuild. It can never create or extend a session;
  /// only the still-valid server verification held in state may be restored.
  bool restoreCredentials() {
    final session = state;
    if (session == null || !isStaffPinSessionCurrent(session.expiresAt)) {
      lock();
      return false;
    }
    StaffPinSessionStore.current = StaffPinSessionCredentials(
      sessionId: session.sessionId,
      sessionToken: session.sessionToken,
      tenantId: session.tenantId,
      venueId: session.venueId,
      deviceId: session.deviceId,
    );
    return true;
  }
}

/// Called from the unlocked app shell so any staff member can rotate their
/// own PIN without access to manager-only settings. Rotating a PIN invalidates
/// all prior sessions, including this one, before returning to the PIN gate.
Future<void> changeCurrentStaffPin({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
}) async {
  final firstPin = await showAppDialog<String>(
    context: context,
    builder: (context) => const _PinPadDialog(
      title: Text('Change your staff PIN'),
      message: 'Choose a new six-digit PIN. Do not share it.',
      confirmLabel: 'Continue',
    ),
  );
  if (firstPin == null || !context.mounted) return;
  final confirmedPin = await showAppDialog<String>(
    context: context,
    builder: (context) => const _PinPadDialog(
      title: Text('Confirm new PIN'),
      message: 'Enter the same new PIN again.',
      confirmLabel: 'Change PIN',
    ),
  );
  if (confirmedPin == null || !context.mounted) return;
  if (firstPin != confirmedPin) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('The two PIN entries did not match.')),
    );
    return;
  }
  try {
    await ProductionCommandRepository().changeOwnStaffPin(
      scope: scope,
      pin: firstPin,
    );
    ref.read(activeStaffPinSessionProvider.notifier).lock();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PIN changed. Please unlock with your new PIN.'),
        ),
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Change own staff PIN', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not change PIN: $error')));
    }
  }
}

class StaffPinGate extends ConsumerStatefulWidget {
  const StaffPinGate({
    super.key,
    required this.scope,
    required this.child,
    required this.onSwitchVenue,
    required this.onSignOut,
    this.backgroundLockSeconds = 120,
    this.offlineHubOnly = false,
  });

  final VenueScope scope;
  final Widget child;
  final VoidCallback onSwitchVenue;
  final VoidCallback onSignOut;
  final int backgroundLockSeconds;
  final bool offlineHubOnly;

  @override
  ConsumerState<StaffPinGate> createState() => _StaffPinGateState();
}

class _StaffPinGateState extends ConsumerState<StaffPinGate>
    with WidgetsBindingObserver {
  final ProductionCommandRepository _repository = ProductionCommandRepository();
  final VenueHubClientCache _hubCache = VenueHubClientCache();
  List<VenuePinStaff>? _staff;
  String? _selectedUserId;
  String? _pinEntryUserId;
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  Timer? _expiryTimer;
  DateTime? _backgroundedAt;

  Duration get _backgroundLockAfter =>
      Duration(seconds: widget.backgroundLockSeconds.clamp(15, 3600));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VenueHubClientRegistry.instance.staffSessionInvalidations.addListener(
      _handleHubStaffSessionInvalidation,
    );
    _loadStaff();
  }

  void _handleHubStaffSessionInvalidation() {
    if (!mounted || ref.read(activeStaffPinSessionProvider) == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(activeStaffPinSessionProvider) == null) return;
      ref.read(activeStaffPinSessionProvider.notifier).lock();
      if (mounted) {
        setState(() {
          _error = 'Your staff session ended. Enter your PIN again.';
          _pinEntryUserId = null;
          _submitting = false;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // Windows reports `inactive` for ordinary focus changes (including a
        // printer/system dialog). Treating that as backgrounding repeatedly
        // returned an attended hub to the PIN screen. Mobile still records it
        // because an incoming system surface can genuinely obscure the POS.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) break;
        _backgroundedAt ??= DateTime.now();
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundedAt ??= DateTime.now();
        break;
      case AppLifecycleState.resumed:
        final backgroundedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (backgroundedAt != null &&
            DateTime.now().difference(backgroundedAt) >= _backgroundLockAfter &&
            !ref.read(orderFlowDisplayActiveProvider)) {
          AppLogger.info(
            'Shared device locked after its configured background timeout.',
          );
          ref.read(activeStaffPinSessionProvider.notifier).lock();
        }
        break;
      case AppLifecycleState.detached:
        ref.read(activeStaffPinSessionProvider.notifier).lock();
        break;
    }
  }

  @override
  void didUpdateWidget(covariant StaffPinGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      ref.read(activeStaffPinSessionProvider.notifier).lock();
      _loadStaff();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VenueHubClientRegistry.instance.staffSessionInvalidations.removeListener(
      _handleHubStaffSessionInvalidation,
    );
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStaff() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.offlineHubOnly) {
        final cached = await _hubCache.readStaff(widget.scope);
        if (cached.isEmpty) {
          throw StateError(
            'No cached staff list is available. Reconnect this hub to the internet once.',
          );
        }
        if (!mounted) return;
        setState(() {
          _staff = cached;
          _selectedUserId = cached.firstOrNull?.userId;
          _loading = false;
          _error = 'Internet unavailable. Using the encrypted venue hub.';
        });
        return;
      }
      final staff = await _repository.listVenuePinStaff(widget.scope);
      // The cache is optional. Its implementation absorbs local-storage
      // failures so a successfully loaded cloud list always opens the PIN
      // screen instead of being misclassified as an offline failure.
      await _hubCache.saveStaff(widget.scope, staff);
      if (!mounted) return;
      final currentUserId = _currentFirebaseUser?.uid;
      setState(() {
        _staff = staff;
        _selectedUserId = staff.any((item) => item.userId == currentUserId)
            ? currentUserId
            : staff.firstOrNull?.userId;
        _loading = false;
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load venue PIN staff', error, stackTrace);
      if (!mounted) return;
      final cached = await _hubCache.readStaff(widget.scope);
      if (cached.isNotEmpty) {
        setState(() {
          _staff = cached;
          _selectedUserId = cached.firstOrNull?.userId;
          _loading = false;
          _error =
              'Cloud unavailable. Using the encrypted venue hub PIN service.';
        });
        return;
      }
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _enterPin(VenuePinStaff staff) async {
    setState(() {
      _pinEntryUserId = staff.userId;
      _error = null;
    });
  }

  /// Verifies a PIN entered on the locked screen.
  ///
  /// Staff login deliberately does not use a modal route. Replacing the PIN
  /// gate with the venue shell while a dialog route is being removed can leave
  /// Flutter's semantics parent data dirty on desktop and halt every following
  /// frame. Keeping the keypad in the gate's own render tree gives the unlock
  /// transition one owner and remains usable with touch or a physical keyboard.
  Future<void> _verifyPin(VenuePinStaff staff, String pin) async {
    try {
      setState(() => _submitting = true);
      AppLogger.info(
        'Staff PIN unlock started: staff=${staff.userId}, '
        'offline=${widget.offlineHubOnly}.',
      );
      VenueHubBootstrap? bootstrap;
      try {
        if (widget.offlineHubOnly) {
          AppLogger.info('Staff PIN unlock: loading cached hub authority.');
          throw const _UseCachedHubBootstrap();
        }
        final rawBootstrap = await _repository.fetchOfflineHubBootstrap(
          scope: widget.scope,
        );
        bootstrap = VenueHubBootstrap.fromJson(rawBootstrap);
        await _hubCache.saveBootstrap(widget.scope, bootstrap);
      } catch (error, stackTrace) {
        if (error is! _UseCachedHubBootstrap) {
          AppLogger.error('Refresh venue hub discovery', error, stackTrace);
        }
        bootstrap = await _hubCache.readBootstrap(widget.scope);
        // The hub host already passed cloud authority checks when its runtime
        // started. Prefer that in-memory authority if the router loses its
        // internet link before PIN entry and the older disk cache is absent or
        // still says disabled. This never helps a different, unenrolled
        // device bypass hub authentication.
        final runningBootstrap =
            VenueHubRuntime.instance.activeScope == widget.scope
            ? VenueHubRuntime.instance.activeBootstrap
            : null;
        if (runningBootstrap?.enabled == true &&
            (bootstrap == null || !bootstrap.enabled)) {
          bootstrap = runningBootstrap;
        }
      }
      if (bootstrap == null) {
        throw StateError(
          'The cloud is unavailable and this device has no saved venue hub configuration.',
        );
      }
      AppLogger.info('Staff PIN unlock: hub authority is ready.');
      final deviceId = await LocalPrinterDeviceIdentity()
          .deviceIdForScope(widget.scope)
          .timeout(const Duration(seconds: 5));
      if (kIsWeb) {
        // Browsers do not retain the hub's native device key. Their
        // PIN-authenticated mutations use the short-lived Firebase queue and
        // are successful only after the authoritative hub commits them.
        VenueHubClientRegistry.instance.rememberBootstrap(
          widget.scope,
          bootstrap,
        );
        final session = await _repository.verifyStaffPin(
          scope: widget.scope,
          userId: staff.userId,
          pin: pin,
          deviceId: deviceId,
        );
        await _hubCache.saveStaffPreferences(
          widget.scope,
          userId: session.userId,
          themeModePreference: session.themeModePreference,
          posCategoryViewPreference: session.posCategoryViewPreference,
          posProductSortPreference: session.posProductSortPreference,
        );
        ref
            .read(activeStaffPinSessionProvider.notifier)
            .unlock(session, widget.scope);
        if (bootstrap.enabled) {
          unawaited(
            VenueHubRealtimeClient.instance
                .ensureConfigured(
                  scope: widget.scope,
                  hubEpoch: bootstrap.hubEpoch,
                  repository: _repository,
                )
                .catchError((Object error, StackTrace stackTrace) {
                  AppLogger.error(
                    'Start realtime POS channel after PIN unlock',
                    error,
                    stackTrace,
                  );
                }),
          );
        }
        _scheduleExpiryCheck();
        return;
      }
      final credential = await VenueHubDeviceCredentialStore()
          .getOrCreate(
            tenantId: widget.scope.tenantId,
            venueId: widget.scope.venueId,
            deviceId: deviceId,
          )
          .timeout(const Duration(seconds: 5));
      AppLogger.info('Staff PIN unlock: device identity is ready.');
      await VenueHubPrinterClientRegistry.instance
          .configure(
            scope: widget.scope,
            bootstrap: bootstrap,
            deviceId: deviceId,
            credential: credential,
          )
          .timeout(const Duration(seconds: 5));
      VenueHubLoginResult? hubLogin;
      StaffPinVerification? migratedCloudSession;
      var hubConnectionUnavailable = false;
      final isLocalHubHost =
          bootstrap.hubDeviceId == deviceId &&
          bootstrap.hubCredentialId == credential.credentialId;
      if (bootstrap.enabled) {
        try {
          final localHubEndpoint = isLocalHubHost
              ? await VenueHubRuntime.instance.waitForLocalEndpoint(
                  widget.scope,
                  timeout: const Duration(seconds: 8),
                )
              : null;
          AppLogger.info(
            'Staff PIN unlock: verifying with the certificate-pinned hub.',
          );
          hubLogin = await VenueHubClientRegistry.instance
              .configure(
                scope: widget.scope,
                bootstrap: bootstrap,
                deviceId: deviceId,
                staffId: staff.userId,
                pin: pin,
                credential: credential,
                endpointOverride: localHubEndpoint,
              )
              .timeout(const Duration(seconds: 12));
          AppLogger.info('Staff PIN unlock: hub verification succeeded.');
        } on VenueHubClientException catch (error) {
          final verifierMissing = error.code == 'offline_verifier_unavailable';
          final verifierRejected = error.code == 'invalid_pin';
          final lanUnavailable = error.code == 'hub_lan_unavailable';
          if (lanUnavailable) {
            if (isLocalHubHost) rethrow;
            // A remote terminal may legitimately be on mobile data or another
            // network. Cloud PIN verification authenticates the staff member;
            // RTDB presence and the signed remote queue still require the
            // authoritative hub to be online before any order is accepted.
            hubConnectionUnavailable = true;
            AppLogger.info(
              'Venue hub LAN login unavailable; continuing with the secure remote hub route.',
            );
          } else if (!verifierMissing && !verifierRejected) {
            rethrow;
          }
          // A LAN transport failure continues below to normal cloud PIN
          // verification. Only the two explicit verifier errors may enter the
          // legacy repair flow and refresh hub secrets.
          if (!lanUnavailable) {
            if (widget.offlineHubOnly) {
              throw StateError(
                verifierMissing
                    ? 'This PIN needs one successful online login before it can be used offline.'
                    : 'The venue hub rejected this staff PIN.',
              );
            }
            AppLogger.info(
              verifierMissing
                  ? 'Upgrading a legacy staff PIN for encrypted offline verification.'
                  : 'Validating and repairing a rejected offline PIN verifier.',
            );
            migratedCloudSession = await _repository.verifyStaffPin(
              scope: widget.scope,
              userId: staff.userId,
              pin: pin,
              deviceId: deviceId,
              repairOfflineVerifier: verifierRejected,
            );
            if (VenueHubRuntime.instance.activeScope != widget.scope) {
              throw StateError(
                'The PIN was upgraded. Wait up to 30 seconds for the venue hub '
                'to refresh, then enter it again.',
              );
            }
            final refreshed = await _repository.fetchOfflineHubSnapshot(
              scope: widget.scope,
              deviceId: deviceId,
              hubEpoch: bootstrap.hubEpoch,
              credential: credential,
            );
            await VenueHubRuntime.instance.installFreshSnapshot(refreshed);
            final localHubEndpoint =
                bootstrap.hubDeviceId == deviceId &&
                    bootstrap.hubCredentialId == credential.credentialId
                ? await VenueHubRuntime.instance.waitForLocalEndpoint(
                    widget.scope,
                  )
                : null;
            hubLogin = await VenueHubClientRegistry.instance.configure(
              scope: widget.scope,
              bootstrap: bootstrap,
              deviceId: deviceId,
              staffId: staff.userId,
              pin: pin,
              credential: credential,
              endpointOverride: localHubEndpoint,
            );
          }
        } on StateError catch (error, stackTrace) {
          if (isLocalHubHost) rethrow;
          // Certificate installation and device enrolment are managed from
          // inside the authenticated Settings area. If Firebase is online,
          // permit a cloud-verified manager to enter that recovery surface.
          // The registry deliberately preserves hub authority, so orders and
          // payments remain fail-closed until this local connection succeeds.
          hubConnectionUnavailable = true;
          AppLogger.error(
            'Venue hub unavailable during online PIN recovery',
            error,
            stackTrace,
          );
        }
      } else {
        VenueHubClientRegistry.instance.rememberBootstrap(
          widget.scope,
          bootstrap,
        );
      }
      final cachedPreferences = await _hubCache
          .readStaffPreferences(widget.scope, staff.userId)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => const <String, String>{},
          );
      StaffPinVerification session;
      if (widget.offlineHubOnly) {
        if (hubLogin == null) {
          throw StateError('The local venue hub did not verify this PIN.');
        }
        session = StaffPinVerification(
          sessionId: hubLogin.sessionId,
          sessionToken: hubLogin.sessionToken,
          expiresAt: hubLogin.expiresAtUtc,
          tenantId: widget.scope.tenantId,
          venueId: widget.scope.venueId,
          deviceId: deviceId,
          userId: staff.userId,
          displayName: staff.displayName,
          isPlatformAdmin: false,
          roles: staff.roles,
          // Preserve the venue default restored from local preferences while
          // Firebase is unavailable. "system" previously passed through a
          // light/dark-only parser and incorrectly forced the light theme.
          themeModePreference:
              cachedPreferences['themeModePreference'] ?? 'venue',
          posCategoryViewPreference:
              cachedPreferences['posCategoryViewPreference'] ?? 'bars',
          posProductSortPreference:
              cachedPreferences['posProductSortPreference'] ?? 'alphabetical',
        );
      } else if (migratedCloudSession != null) {
        session = migratedCloudSession;
      } else {
        try {
          session = await _repository.verifyStaffPin(
            scope: widget.scope,
            userId: staff.userId,
            pin: pin,
            deviceId: deviceId,
          );
        } catch (error, stackTrace) {
          if (!bootstrap.enabled || hubLogin == null) rethrow;
          AppLogger.error(
            'Cloud PIN verification unavailable; using venue hub grant',
            error,
            stackTrace,
          );
          session = StaffPinVerification(
            sessionId: hubLogin.sessionId,
            sessionToken: hubLogin.sessionToken,
            expiresAt: hubLogin.expiresAtUtc,
            tenantId: widget.scope.tenantId,
            venueId: widget.scope.venueId,
            deviceId: deviceId,
            userId: staff.userId,
            displayName: staff.displayName,
            isPlatformAdmin: false,
            roles: staff.roles,
            themeModePreference:
                cachedPreferences['themeModePreference'] ?? 'venue',
            posCategoryViewPreference:
                cachedPreferences['posCategoryViewPreference'] ?? 'bars',
            posProductSortPreference:
                cachedPreferences['posProductSortPreference'] ?? 'alphabetical',
          );
        }
      }
      if (hubLogin != null &&
          hubLogin.expiresAtUtc.isBefore(session.expiresAt)) {
        session = session.copyWith(expiresAt: hubLogin.expiresAtUtc);
      }
      await _hubCache
          .saveStaffPreferences(
            widget.scope,
            userId: session.userId,
            themeModePreference: session.themeModePreference,
            posCategoryViewPreference: session.posCategoryViewPreference,
            posProductSortPreference: session.posProductSortPreference,
          )
          .timeout(const Duration(seconds: 5), onTimeout: () {});
      AppLogger.info('Staff PIN unlock: activating the verified session.');
      ref
          .read(activeStaffPinSessionProvider.notifier)
          .unlock(session, widget.scope);
      if (bootstrap.enabled && !widget.offlineHubOnly) {
        unawaited(
          VenueHubRealtimeClient.instance
              .ensureConfigured(
                scope: widget.scope,
                hubEpoch: bootstrap.hubEpoch,
                repository: _repository,
              )
              .catchError((Object error, StackTrace stackTrace) {
                AppLogger.error(
                  'Start realtime POS channel after PIN unlock',
                  error,
                  stackTrace,
                );
              }),
        );
      }
      if (bootstrap.enabled && hubLogin == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              hubConnectionUnavailable
                  ? 'Local hub connection unavailable. Connecting through the secure remote hub channel; orders remain blocked until live hub presence is confirmed.'
                  : 'Signed in for recovery only. Enrol this device in Venue offline hub settings before it can process orders.',
            ),
          ),
        );
      }
      _scheduleExpiryCheck();
      AppLogger.info('Shared device unlocked for staff=${staff.userId}.');
    } on Object catch (error, stackTrace) {
      AppLogger.error('Verify staff PIN', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _pinEntryUserId = null;
      });
      await _loadStaff();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _scheduleExpiryCheck() {
    _expiryTimer?.cancel();
    final session = ref.read(activeStaffPinSessionProvider);
    if (session == null) return;
    final remaining = _staffPinSessionRemaining(session.expiresAt);
    _expiryTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      final current = ref.read(activeStaffPinSessionProvider);
      if (current == null) return;
      if (isStaffPinSessionCurrent(current.expiresAt)) {
        _scheduleExpiryCheck();
      } else if (ref.read(orderFlowDisplayActiveProvider)) {
        _expiryTimer = Timer(const Duration(seconds: 30), _scheduleExpiryCheck);
      } else {
        ref.read(activeStaffPinSessionProvider.notifier).lock();
      }
    });
  }

  void _dismissProtectedRoutesAfterLock() {
    if (!mounted) return;
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null || !navigator.canPop()) return;
    AppLogger.info(
      'Staff PIN session locked; closing protected dialogs and sheets.',
    );
    navigator.popUntil((route) => route.isFirst);
  }

  Future<void> _setOwnPin() async {
    try {
      final firstPin = await showAppDialog<String>(
        context: context,
        builder: (context) => const _PinPadDialog(
          title: Text('Create your staff PIN'),
          message: 'Choose six digits. Do not share this PIN.',
          confirmLabel: 'Continue',
        ),
      );
      if (firstPin == null || !mounted) return;
      final confirmedPin = await showAppDialog<String>(
        context: context,
        builder: (context) => const _PinPadDialog(
          title: Text('Confirm your staff PIN'),
          message: 'Enter the same six digits again.',
          confirmLabel: 'Save PIN',
        ),
      );
      if (confirmedPin == null || !mounted) return;
      if (confirmedPin != firstPin) {
        setState(
          () => _error = 'The two PIN entries did not match. Try again.',
        );
        return;
      }
      setState(() => _submitting = true);
      await _repository.setOwnStaffPin(scope: widget.scope, pin: firstPin);
      await _loadStaff();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Set own staff PIN', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _recoverOwnPin(VenuePinStaff staff) async {
    final user = _currentFirebaseUser;
    final email = user?.email;
    if (user == null || user.uid != staff.userId || email == null) {
      setState(() {
        _error =
            'Sign out of this device account and sign in with your own email before recovering your PIN.';
      });
      return;
    }
    final password = await showAppDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PasswordReauthenticationDialog(email: email),
    );
    if (password == null || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      AppLogger.info('PIN recovery: verifying Firebase account password.');
      final recentlyAuthenticatedIdToken = await _repository
          .verifyPasswordForPinRecovery(
            email: email,
            password: password,
            expectedUserId: user.uid,
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'Firebase account verification timed out. Check the connection and try again.',
            ),
          );
      AppLogger.info('PIN recovery: Firebase account password verified.');
      if (!mounted) return;
      AppLogger.info('PIN recovery: opening replacement PIN entry.');
      final newPin = await showAppDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _PinPadDialog(
          title: Text('Choose a new staff PIN'),
          message: 'Choose a new six-digit PIN that only you know.',
          confirmLabel: 'Continue',
        ),
      );
      if (newPin == null || !mounted) return;
      final confirmation = await showAppDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _PinPadDialog(
          title: Text('Confirm new staff PIN'),
          message: 'Enter the same new PIN again.',
          confirmLabel: 'Reset PIN',
        ),
      );
      if (confirmation == null || !mounted) return;
      if (newPin != confirmation) {
        setState(() => _error = 'The two new PIN entries did not match.');
        return;
      }
      AppLogger.info('PIN recovery: submitting replacement PIN securely.');
      await _repository
          .recoverOwnStaffPin(
            scope: widget.scope,
            newPin: newPin,
            recentlyAuthenticatedIdToken: recentlyAuthenticatedIdToken,
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'The PIN reset request timed out. Check the connection and try again.',
            ),
          );
      AppLogger.info('PIN recovery: replacement PIN saved successfully.');
      await _loadStaff();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PIN reset securely. Enter your new PIN to continue.'),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Recover own staff PIN', error, stackTrace);
      if (mounted) setState(() => _error = 'Could not reset PIN: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Dialogs and modal sheets are routes above this gate. Without explicitly
    // dismissing them, an expired session can correctly rebuild the PIN screen
    // underneath a checkout sheet while leaving that protected sheet visible.
    ref.listen<StaffPinVerification?>(activeStaffPinSessionProvider, (
      previous,
      next,
    ) {
      if (previous != null && next == null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _dismissProtectedRoutesAfterLock(),
        );
      }
    });
    final session = ref.watch(activeStaffPinSessionProvider);
    if (session != null && isStaffPinSessionCurrent(session.expiresAt)) {
      return widget.child;
    }
    final staff = _staff ?? const <VenuePinStaff>[];
    final selected = staff
        .where((item) => item.userId == _selectedUserId)
        .firstOrNull;
    final pinEntryStaff = staff
        .where((item) => item.userId == _pinEntryUserId)
        .firstOrNull;
    final currentUserId = _currentFirebaseUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff PIN'),
        actions: [
          IconButton(
            tooltip: 'Switch venue',
            onPressed: _submitting ? null : widget.onSwitchVenue,
            icon: const Icon(Icons.storefront_outlined),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _submitting ? null : widget.onSignOut,
            icon: const Icon(Icons.logout_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          // PIN entry must fit without scrolling on short POS tablets. The
          // staff picker keeps its roomier layout, while the keypad removes
          // decorative padding and sizes its keys from the actual viewport.
          padding: EdgeInsets.all(pinEntryStaff == null ? 24 : 8),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: pinEntryStaff == null ? 760 : 430,
              ),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(pinEntryStaff == null ? 28 : 12),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : pinEntryStaff != null
                      ? _PinPadPanel(
                          key: ValueKey(pinEntryStaff.userId),
                          title: Text(
                            'Enter PIN for ${pinEntryStaff.displayName}',
                          ),
                          message: 'Enter your six-digit staff PIN.',
                          confirmLabel: 'Unlock',
                          enabled: !_submitting,
                          onCancel: () {
                            if (_submitting) return;
                            setState(() => _pinEntryUserId = null);
                          },
                          onSubmitted: (pin) => _verifyPin(pinEntryStaff, pin),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Who is using this device?',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Tap your name, then enter your personal six-digit PIN.',
                            ),
                            const SizedBox(height: 20),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final columns = constraints.maxWidth >= 620
                                    ? 4
                                    : constraints.maxWidth >= 420
                                    ? 3
                                    : 2;
                                const spacing = 10.0;
                                final tileWidth =
                                    (constraints.maxWidth -
                                        (spacing * (columns - 1))) /
                                    columns;
                                return Wrap(
                                  spacing: spacing,
                                  runSpacing: spacing,
                                  children: [
                                    for (final item in staff)
                                      SizedBox(
                                        width: tileWidth,
                                        child: _StaffTile(
                                          staff: item,
                                          selected:
                                              item.userId == _selectedUserId,
                                          enabled: !_submitting,
                                          onTap: () async {
                                            setState(() {
                                              _selectedUserId = item.userId;
                                              _error = null;
                                            });
                                            if (item.pinLocked) return;
                                            if (item.hasPin) {
                                              await _enterPin(item);
                                            } else if (item.userId ==
                                                currentUserId) {
                                              await _setOwnPin();
                                            }
                                          },
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            if (selected?.pinLocked == true) ...[
                              const Text(
                                'This PIN is locked after three failed attempts.',
                              ),
                              if (selected?.userId == currentUserId) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  'Verify this staff member’s Firebase account password, then choose a new PIN. No email extension is required.',
                                ),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _submitting
                                      ? null
                                      : () => _recoverOwnPin(selected!),
                                  icon: const Icon(
                                    Icons.verified_user_outlined,
                                  ),
                                  label: Text(
                                    _submitting
                                        ? 'Resetting PIN…'
                                        : 'Verify account and reset PIN',
                                  ),
                                ),
                              ] else ...[
                                const Text(
                                  'Ask another manager to unlock it, or sign out and sign in with your own email to reset it securely.',
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _submitting
                                      ? null
                                      : widget.onSignOut,
                                  icon: const Icon(Icons.logout_rounded),
                                  label: const Text('Sign in with my email'),
                                ),
                              ],
                            ] else if (selected?.hasPin == true)
                              FilledButton.icon(
                                onPressed: _submitting
                                    ? null
                                    : () => _enterPin(selected!),
                                icon: const Icon(Icons.lock_open_rounded),
                                label: Text(
                                  _submitting ? 'Checking…' : 'Enter PIN',
                                ),
                              )
                            else if (selected?.userId == currentUserId)
                              FilledButton.icon(
                                onPressed: _submitting ? null : _setOwnPin,
                                icon: const Icon(Icons.pin_rounded),
                                label: const Text('Create my PIN'),
                              )
                            else if (selected != null)
                              const Text(
                                'This staff member has not created a PIN yet. For safety, they must first sign in with their own email account and create it; a shared device account cannot create someone else’s PIN.',
                              )
                            else
                              const Text(
                                'This staff member must sign in with email and create their PIN first.',
                              ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _submitting ? null : _loadStaff,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Refresh staff'),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
