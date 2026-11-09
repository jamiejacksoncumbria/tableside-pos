import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import 'transient_realtime_database.dart';
import 'venue_hub_availability.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_platform.dart';
import 'windows_realtime_rest_session.dart';

/// Measures how long the server-owned authority lease has stopped advancing
/// with a monotonic clock. Wall-clock comparisons are unsafe here because an
/// Android terminal can be minutes or hours away from Firebase server time.
@visibleForTesting
class VenueHubLeaseSilenceTracker {
  VenueHubLeaseSilenceTracker({this.monotonicMicroseconds}) {
    _stopwatch.start();
  }

  final int Function()? monotonicMicroseconds;
  final Stopwatch _stopwatch = Stopwatch();
  int? _lastReadyAtMillis;
  int? _observedAtMicroseconds;

  int get _nowMicroseconds =>
      monotonicMicroseconds?.call() ?? _stopwatch.elapsedMicroseconds;

  void observe(Object? lastReadyAt) {
    if (lastReadyAt is! int || lastReadyAt <= 0) return;
    if (_lastReadyAtMillis == lastReadyAt) return;
    _lastReadyAtMillis = lastReadyAt;
    _observedAtMicroseconds = _nowMicroseconds;
  }

  bool isSilentFor(Duration duration) {
    final observedAt = _observedAtMicroseconds;
    if (observedAt == null) return false;
    return _nowMicroseconds - observedAt >= duration.inMicroseconds;
  }

  void reset() {
    _lastReadyAtMillis = null;
    _observedAtMicroseconds = null;
  }
}

/// Describes a backup device whose primary hub lease has stopped advancing.
/// This is deliberately only a request for human attention: observing an
/// expired lease never grants authority and never starts the backup runtime.
class VenueHubManualTakeoverRequest {
  const VenueHubManualTakeoverRequest({
    required this.scope,
    required this.primaryDeviceId,
    required this.detectedAt,
  });

  final VenueScope scope;
  final String primaryDeviceId;
  final DateTime detectedAt;
}

/// Process-wide bridge between the passive backup monitor and the manager
/// settings page. The callback is installed only by the configured backup
/// monitor, keeping credentials and authority changes out of UI state.
class VenueHubManualTakeoverCoordinator {
  VenueHubManualTakeoverCoordinator._();

  static final instance = VenueHubManualTakeoverCoordinator._();

  final ValueNotifier<VenueHubManualTakeoverRequest?> pending =
      ValueNotifier<VenueHubManualTakeoverRequest?>(null);
  Future<void> Function(String managerPin, String reason)? _confirm;

  void bind(Future<void> Function(String managerPin, String reason) confirm) {
    _confirm = confirm;
  }

  void requireConfirmation(VenueHubManualTakeoverRequest request) {
    final current = pending.value;
    if (current?.scope == request.scope &&
        current?.primaryDeviceId == request.primaryDeviceId) {
      return;
    }
    pending.value = request;
  }

  void clear() => pending.value = null;

  void unbind() {
    _confirm = null;
    clear();
  }

  Future<void> confirm({
    required String managerPin,
    required String reason,
  }) async {
    final callback = _confirm;
    if (pending.value == null || callback == null) {
      throw StateError(
        'The primary hub is not currently eligible for manual takeover.',
      );
    }
    await callback(managerPin, reason);
  }
}

/// Keeps a configured backup passive and asks a manager to intervene when the
/// primary's server-owned RTDB lease is stale. It never promotes itself. The
/// backend repeats the lease test in an atomic authority transaction after a
/// fresh manager PIN and explicit acknowledgement are supplied.
class VenueHubBackupMonitor {
  VenueHubBackupMonitor({ProductionCommandRepository? repository})
    : _repository = repository ?? ProductionCommandRepository();

  static const _secondaryAppName = 'tableside-hub-backup';
  static const _staleAfter = Duration(seconds: 30);
  final ProductionCommandRepository _repository;
  StreamSubscription<dynamic>? _authoritySubscription;
  WindowsRealtimeRestSession? _windowsSession;
  FirebaseApp? _app;
  Timer? _timer;
  Map<Object?, Object?>? _latestAuthority;
  final VenueHubLeaseSilenceTracker _leaseSilence =
      VenueHubLeaseSilenceTracker();
  bool _takingOver = false;
  Future<void> Function(int hubEpoch)? _onPromoted;
  VenueScope? _scope;
  String? _deviceId;
  VenueHubDeviceCredential? _credential;
  VenueHubBootstrap? _bootstrap;
  bool _holdsAndroidService = false;

  Future<void> start({
    required VenueScope scope,
    required String deviceId,
    required VenueHubDeviceCredential credential,
    required VenueHubBootstrap bootstrap,
    required Future<void> Function(int hubEpoch) onPromoted,
  }) async {
    await stop();
    if (bootstrap.backupDeviceId != deviceId ||
        bootstrap.backupCredentialId != credential.credentialId) {
      throw StateError('This device is not the configured backup hub.');
    }
    _scope = scope;
    _deviceId = deviceId;
    _credential = credential;
    _bootstrap = bootstrap;
    _onPromoted = onPromoted;
    VenueHubManualTakeoverCoordinator.instance.bind(_confirmTakeover);
    final session = await _repository.issueRealtimeBackupHubSession(
      scope: scope,
      deviceId: deviceId,
      hubEpoch: bootstrap.hubEpoch,
      credential: credential,
    );
    final token = session['customToken'];
    final databaseUrl = session['databaseUrl'];
    if (token is! String || token.isEmpty || databaseUrl is! String) {
      throw StateError('The server returned an invalid backup hub session.');
    }
    final primary = Firebase.app();
    final path = 'hubAuthorities/${scope.tenantId}/${scope.venueId}';
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final windowsSession = WindowsRealtimeRestSession(
        databaseUrl: databaseUrl,
        apiKey: primary.options.apiKey,
        customToken: token,
        renewCustomToken: () async {
          final renewed = await _repository.issueRealtimeBackupHubSession(
            scope: scope,
            deviceId: deviceId,
            hubEpoch: bootstrap.hubEpoch,
            credential: credential,
          );
          final renewedToken = renewed['customToken'];
          if (renewedToken is! String || renewedToken.isEmpty) {
            throw StateError('The backup hub session could not be renewed.');
          }
          return renewedToken;
        },
      );
      _windowsSession = windowsSession;
      await windowsSession.authenticate();
      _authoritySubscription = windowsSession
          .watch(path)
          .listen(
            _receiveAuthority,
            onError: (Object error, StackTrace stackTrace) => AppLogger.error(
              'Watch primary hub authority from backup',
              error,
              stackTrace,
            ),
          );
    } else {
      FirebaseApp app;
      try {
        app = Firebase.app(_secondaryAppName);
      } on FirebaseException {
        app = await Firebase.initializeApp(
          name: _secondaryAppName,
          options: primary.options.copyWith(databaseURL: databaseUrl),
        );
      }
      _app = app;
      await FirebaseAuth.instanceFor(app: app).signInWithCustomToken(token);
      final database = TransientRealtimeDatabase.instanceFor(
        app: app,
        databaseUrl: databaseUrl,
      );
      _authoritySubscription = database
          .ref(path)
          .onValue
          .listen(
            (event) => _receiveAuthority(event.snapshot.value),
            onError: (Object error, StackTrace stackTrace) => AppLogger.error(
              'Watch primary hub authority from backup',
              error,
              stackTrace,
            ),
          );
    }
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_checkFailover()),
    );
    await AndroidVenueHubService.start(standby: true);
    _holdsAndroidService = true;
    AppLogger.info('Backup venue hub is armed in passive standby mode.');
  }

  void _receiveAuthority(Object? raw) {
    if (raw is Map) {
      final previousReadyAt = _latestAuthority?['lastReadyAt'];
      _latestAuthority = Map<Object?, Object?>.from(raw);
      _leaseSilence.observe(raw['lastReadyAt']);
      if (raw['lastReadyAt'] is int && raw['lastReadyAt'] != previousReadyAt) {
        VenueHubManualTakeoverCoordinator.instance.clear();
        VenueHubAvailability.markOnline();
      }
      unawaited(_checkFailover());
    }
  }

  Future<void> _checkFailover() async {
    if (_takingOver) return;
    final authority = _latestAuthority;
    final scope = _scope;
    final deviceId = _deviceId;
    final credential = _credential;
    final bootstrap = _bootstrap;
    if (authority == null ||
        scope == null ||
        deviceId == null ||
        credential == null ||
        bootstrap == null ||
        authority['enabled'] != true ||
        authority['deviceId'] != bootstrap.hubDeviceId ||
        authority['hubEpoch'] != bootstrap.hubEpoch) {
      return;
    }
    final lastReadyAt = authority['lastReadyAt'];
    if (lastReadyAt is! int || !_leaseSilence.isSilentFor(_staleAfter)) {
      return;
    }
    final primaryDeviceId = authority['deviceId'];
    if (primaryDeviceId is! String || primaryDeviceId.isEmpty) return;
    VenueHubManualTakeoverCoordinator.instance.requireConfirmation(
      VenueHubManualTakeoverRequest(
        scope: scope,
        primaryDeviceId: primaryDeviceId,
        detectedAt: DateTime.now(),
      ),
    );
    VenueHubAvailability.markOffline(
      'The primary venue hub appears offline. Orders remain blocked until a '
      'manager confirms takeover in Settings > Venue offline hub.',
    );
    AppLogger.info(
      'Primary hub authority lease stopped advancing; manual manager takeover '
      'is required. No authority change was attempted automatically.',
    );
  }

  Future<void> _confirmTakeover(String managerPin, String reason) async {
    if (_takingOver) {
      throw StateError('A hub takeover request is already in progress.');
    }
    final scope = _scope;
    final deviceId = _deviceId;
    final credential = _credential;
    final bootstrap = _bootstrap;
    if (scope == null ||
        deviceId == null ||
        credential == null ||
        bootstrap == null ||
        VenueHubManualTakeoverCoordinator.instance.pending.value?.scope !=
            scope) {
      throw StateError('The backup hub configuration is no longer current.');
    }
    _takingOver = true;
    try {
      final promotion = await _repository.promoteOfflineBackupHub(
        scope: scope,
        deviceId: deviceId,
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
        managerPin: managerPin,
        reason: reason,
      );
      final promotedEpoch = promotion['hubEpoch'];
      if (promotedEpoch is! int || promotedEpoch <= bootstrap.hubEpoch) {
        throw StateError('The server returned an invalid promoted hub epoch.');
      }
      VenueHubManualTakeoverCoordinator.instance.clear();
      AppLogger.info(
        'A manager confirmed backup takeover; the server transferred hub authority.',
      );
      final onPromoted = _onPromoted;
      if (onPromoted != null) await onPromoted(promotedEpoch);
    } finally {
      _takingOver = false;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _authoritySubscription?.cancel();
    _authoritySubscription = null;
    await _windowsSession?.close();
    _windowsSession = null;
    final app = _app;
    _app = null;
    if (app != null) {
      try {
        await FirebaseAuth.instanceFor(app: app).signOut();
      } on Object {
        // Scoped tokens expire quickly and have read-only standby claims.
      }
    }
    _latestAuthority = null;
    _leaseSilence.reset();
    _scope = null;
    _deviceId = null;
    _credential = null;
    _bootstrap = null;
    _onPromoted = null;
    VenueHubManualTakeoverCoordinator.instance.unbind();
    if (_holdsAndroidService) {
      _holdsAndroidService = false;
      await AndroidVenueHubService.stop();
    }
  }
}
