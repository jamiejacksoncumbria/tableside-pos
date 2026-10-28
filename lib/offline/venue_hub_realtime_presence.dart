import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import 'transient_realtime_database.dart';
import 'venue_hub_device_credential.dart';
import 'windows_realtime_rest_session.dart';

/// Interprets only a complete, authenticated RTDB authority document.
///
/// `null` means no authority decision was received. In particular, a socket
/// error, an empty initial SSE value, or an internet outage must never be
/// converted into revocation: the encrypted LAN hub is designed to continue
/// operating during exactly that partition. A complete document which is
/// disabled or names a different hub/epoch is an explicit revocation.
bool? parseVenueHubAuthority(
  Object? raw, {
  required String deviceId,
  required int hubEpoch,
}) {
  if (raw is! Map || raw['enabled'] is! bool) return null;
  if (raw['enabled'] == false) return false;
  final authorityDeviceId = raw['deviceId'];
  final authorityEpoch = raw['hubEpoch'];
  if (authorityDeviceId is! String || authorityEpoch is! int) return null;
  return authorityDeviceId == deviceId && authorityEpoch == hubEpoch;
}

/// Maintains server-observed hub presence without a periodic Cloud Function.
class VenueHubRealtimePresence {
  VenueHubRealtimePresence({ProductionCommandRepository? repository})
    : _repository = repository ?? ProductionCommandRepository();

  static const _secondaryAppName = 'tableside-hub-presence';
  final ProductionCommandRepository _repository;
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  final StreamController<void> _commandSignals =
      StreamController<void>.broadcast();
  final StreamController<bool> _authority = StreamController<bool>.broadcast();
  StreamSubscription<dynamic>? _connectionSubscription;
  StreamSubscription<dynamic>? _signalSubscription;
  StreamSubscription<dynamic>? _authoritySubscription;
  DatabaseReference? _presence;
  OnDisconnect? _onDisconnect;
  Timer? _leaseTimer;
  FirebaseApp? _app;
  WindowsRealtimeRestSession? _windowsSession;
  String? _windowsPresencePath;

  /// Emits only a wake-up hint; the hub still claims and validates each
  /// command through the signed POS API before committing it locally.
  Stream<void> get commandSignals => _commandSignals.stream;
  Stream<bool> get authority => _authority.stream;
  bool get started => _presence != null || _windowsSession != null;

  Future<void> start({
    required VenueScope scope,
    required String deviceId,
    required int hubEpoch,
    required VenueHubDeviceCredential credential,
  }) async {
    await stop();
    final session = await _repository.issueRealtimeHubSession(
      scope: scope,
      deviceId: deviceId,
      hubEpoch: hubEpoch,
      credential: credential,
    );
    final token = session['customToken'];
    final databaseUrl = session['databaseUrl'];
    if (token is! String ||
        token.isEmpty ||
        databaseUrl is! String ||
        !databaseUrl.startsWith('https://')) {
      throw StateError('The server returned an invalid realtime hub session.');
    }

    final primary = Firebase.app();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final windowsSession = WindowsRealtimeRestSession(
        databaseUrl: databaseUrl,
        apiKey: primary.options.apiKey,
        customToken: token,
      );
      _windowsSession = windowsSession;
      await windowsSession.authenticate();
      final presencePath =
          'hubPresence/${scope.tenantId}/${scope.venueId}/$deviceId';
      _windowsPresencePath = presencePath;
      _signalSubscription = windowsSession
          .watch('hubSignals/${scope.tenantId}/${scope.venueId}')
          .listen(
            (_) => _commandSignals.add(null),
            onError: (Object error, StackTrace stackTrace) => AppLogger.error(
              'Listen for realtime hub commands',
              error,
              stackTrace,
            ),
          );
      _authoritySubscription = windowsSession
          .watch('hubAuthorities/${scope.tenantId}/${scope.venueId}')
          .listen(
            (raw) {
              final active = parseVenueHubAuthority(
                raw,
                deviceId: deviceId,
                hubEpoch: hubEpoch,
              );
              if (active != null) {
                if (active) connected.value = true;
                _authority.add(active);
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              // Loss of RTDB is an internet outage, not evidence that another
              // device has taken authority. Keep the LAN hub alive and let the
              // authenticated authority document decide after reconnection.
              connected.value = false;
              AppLogger.error(
                'Watch venue hub realtime authority; LAN remains active',
                error,
                stackTrace,
              );
            },
          );
      await windowsSession.set(presencePath, <String, Object?>{
        'online': true,
        'hubEpoch': hubEpoch,
        'connectedAt': WindowsRealtimeRestSession.serverTimestamp,
        'lastReadyAt': WindowsRealtimeRestSession.serverTimestamp,
      });
      connected.value = true;
      AppLogger.info('Venue hub realtime presence connected over Windows SSE.');
      var leaseFailureReported = false;
      _leaseTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (_windowsPresencePath != presencePath) return;
        try {
          await windowsSession.update(presencePath, <String, Object?>{
            'online': true,
            'hubEpoch': hubEpoch,
            'lastReadyAt': WindowsRealtimeRestSession.serverTimestamp,
          });
          final restored = !connected.value;
          connected.value = true;
          leaseFailureReported = false;
          if (restored) {
            AppLogger.info(
              'Venue hub internet connection restored; realtime presence republished.',
            );
          }
        } on Object catch (error, stackTrace) {
          final firstFailure = !leaseFailureReported;
          connected.value = false;
          if (firstFailure) {
            leaseFailureReported = true;
            AppLogger.error(
              'Refresh venue hub realtime lease',
              error,
              stackTrace,
            );
          }
        }
      });
      return;
    }
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
    final presence = database.ref(
      'hubPresence/${scope.tenantId}/${scope.venueId}/$deviceId',
    );
    _presence = presence;
    _signalSubscription = database
        .ref('hubSignals/${scope.tenantId}/${scope.venueId}')
        .onValue
        .listen(
          (_) => _commandSignals.add(null),
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Listen for realtime hub commands',
              error,
              stackTrace,
            );
          },
        );
    _authoritySubscription = database
        .ref('hubAuthorities/${scope.tenantId}/${scope.venueId}')
        .onValue
        .listen(
          (event) {
            final active = parseVenueHubAuthority(
              event.snapshot.value,
              deviceId: deviceId,
              hubEpoch: hubEpoch,
            );
            if (active != null) _authority.add(active);
          },
          onError: (Object error, StackTrace stackTrace) {
            connected.value = false;
            AppLogger.error(
              'Watch venue hub realtime authority; LAN remains active',
              error,
              stackTrace,
            );
          },
        );
    _connectionSubscription = database
        .ref('.info/connected')
        .onValue
        .listen(
          (event) async {
            final online = event.snapshot.value == true;
            if (!online) {
              connected.value = false;
              return;
            }
            try {
              final disconnect = presence.onDisconnect();
              _onDisconnect = disconnect;
              // Arm the server-side disconnect write before publishing online.
              // If power or networking fails after this point, Firebase marks
              // the hub offline without waiting for a Cloud Function timer.
              await disconnect.set(<String, Object?>{
                'online': false,
                'hubEpoch': hubEpoch,
                'disconnectedAt': ServerValue.timestamp,
              });
              await presence.set(<String, Object?>{
                'online': true,
                'hubEpoch': hubEpoch,
                'connectedAt': ServerValue.timestamp,
                'lastReadyAt': ServerValue.timestamp,
              });
              connected.value = true;
              AppLogger.info('Venue hub realtime presence connected.');
            } on Object catch (error, stackTrace) {
              connected.value = false;
              AppLogger.error(
                'Publish venue hub realtime presence',
                error,
                stackTrace,
              );
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            connected.value = false;
            AppLogger.error('Venue hub realtime presence', error, stackTrace);
          },
        );
    // Refresh often enough to detect a suspended hub within seconds even if
    // the RTDB socket's onDisconnect signal is delayed by the network.
    var leaseFailureReported = false;
    _leaseTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_presence != presence) return;
      try {
        await presence.update(<String, Object?>{
          'online': true,
          'hubEpoch': hubEpoch,
          'lastReadyAt': ServerValue.timestamp,
        });
        final restored = !connected.value;
        connected.value = true;
        leaseFailureReported = false;
        if (restored) {
          AppLogger.info(
            'Venue hub internet connection restored; realtime presence republished.',
          );
        }
      } on Object catch (error, stackTrace) {
        final firstFailure = !leaseFailureReported;
        connected.value = false;
        if (firstFailure) {
          leaseFailureReported = true;
          AppLogger.error(
            'Refresh venue hub realtime lease',
            error,
            stackTrace,
          );
        }
      }
    });
  }

  Future<void> stop() async {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _signalSubscription?.cancel();
    _signalSubscription = null;
    await _authoritySubscription?.cancel();
    _authoritySubscription = null;
    final windowsSession = _windowsSession;
    final windowsPresencePath = _windowsPresencePath;
    _windowsSession = null;
    _windowsPresencePath = null;
    if (windowsSession != null) {
      if (windowsPresencePath != null) {
        try {
          await windowsSession.update(windowsPresencePath, <String, Object?>{
            'online': false,
            'disconnectedAt': WindowsRealtimeRestSession.serverTimestamp,
          });
        } on Object {
          // The lease becomes stale within fifteen seconds if shutdown cannot
          // publish the explicit offline state.
        }
      }
      await windowsSession.close();
    }
    try {
      await _onDisconnect?.cancel();
      await _presence?.update(<String, Object?>{
        'online': false,
        'disconnectedAt': ServerValue.timestamp,
      });
    } on Object {
      // The server-side onDisconnect remains armed if cleanup cannot run.
    }
    _onDisconnect = null;
    _presence = null;
    connected.value = false;
    final app = _app;
    _app = null;
    if (app != null) {
      try {
        await FirebaseAuth.instanceFor(app: app).signOut();
      } on Object {
        // The scoped identity cannot access another venue or hub epoch.
      }
    }
  }
}
