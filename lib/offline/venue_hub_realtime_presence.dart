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
  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  StreamSubscription<DatabaseEvent>? _signalSubscription;
  StreamSubscription<DatabaseEvent>? _authoritySubscription;
  DatabaseReference? _presence;
  OnDisconnect? _onDisconnect;
  Timer? _leaseTimer;
  FirebaseApp? _app;

  /// Emits only a wake-up hint; the hub still claims and validates each
  /// command through the signed POS API before committing it locally.
  Stream<void> get commandSignals => _commandSignals.stream;
  Stream<bool> get authority => _authority.stream;
  bool get started => _presence != null;

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
        .listen((event) {
          final raw = event.snapshot.value;
          final value = raw is Map ? raw : const <Object?, Object?>{};
          _authority.add(
            value['enabled'] == true &&
                value['deviceId'] == deviceId &&
                value['hubEpoch'] == hubEpoch,
          );
        }, onError: (Object _, StackTrace _) => _authority.add(false));
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
    _leaseTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!connected.value || _presence != presence) return;
      try {
        await presence.update(<String, Object?>{
          'online': true,
          'hubEpoch': hubEpoch,
          'lastReadyAt': ServerValue.timestamp,
        });
      } on Object catch (error, stackTrace) {
        connected.value = false;
        AppLogger.error('Refresh venue hub realtime lease', error, stackTrace);
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
