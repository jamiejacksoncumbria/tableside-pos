import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../../offline/transient_realtime_database.dart';

/// Publishes enrolled printer presence over RTDB and wakes its worker without
/// periodic Cloud Function heartbeat calls. Claims and completions still use
/// the credential-checked POS API, so presence can never print a ticket.
class PrinterRealtimePresence {
  PrinterRealtimePresence({ProductionCommandRepository? repository})
    : _repository = repository ?? ProductionCommandRepository();

  static const _secondaryAppName = 'tableside-printer-realtime';
  final ProductionCommandRepository _repository;
  final StreamController<void> _signals = StreamController<void>.broadcast();
  Stream<void> get signals => _signals.stream;

  VenueScope? _scope;
  String? _deviceId;
  FirebaseApp? _app;
  DatabaseReference? _presence;
  OnDisconnect? _onDisconnect;
  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  StreamSubscription<DatabaseEvent>? _signalSubscription;
  Timer? _leaseTimer;

  bool isConfigured(VenueScope scope, String deviceId) =>
      _scope == scope && _deviceId == deviceId && _presence != null;

  Future<void> start({
    required VenueScope scope,
    required String deviceId,
    required String deviceCredential,
  }) async {
    if (isConfigured(scope, deviceId)) return;
    await stop();
    final session = await _repository.issueRealtimePrinterSession(
      scope: scope,
      deviceId: deviceId,
      deviceCredential: deviceCredential,
    );
    final token = session['customToken'];
    final databaseUrl = session['databaseUrl'];
    if (token is! String || token.isEmpty || databaseUrl is! String) {
      throw StateError('The server returned an invalid printer session.');
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
      'printerPresence/${scope.tenantId}/${scope.venueId}/$deviceId',
    );
    _scope = scope;
    _deviceId = deviceId;
    _presence = presence;
    _signalSubscription = database
        .ref('printerSignals/${scope.tenantId}/${scope.venueId}/$deviceId')
        .onValue
        .listen((_) => _signals.add(null));
    _connectionSubscription = database.ref('.info/connected').onValue.listen(
      (event) async {
        if (event.snapshot.value != true) return;
        final disconnect = presence.onDisconnect();
        _onDisconnect = disconnect;
        await disconnect.set(<String, Object?>{
          'online': false,
          'disconnectedAt': ServerValue.timestamp,
        });
        await presence.set(<String, Object?>{
          'online': true,
          'lastReadyAt': ServerValue.timestamp,
        });
      },
      onError: (Object error, StackTrace stackTrace) => AppLogger.error(
        'Publish printer realtime presence',
        error,
        stackTrace,
      ),
    );
    _leaseTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_presence != presence) return;
      try {
        await presence.update(<String, Object?>{
          'online': true,
          'lastReadyAt': ServerValue.timestamp,
        });
      } on Object catch (error, stackTrace) {
        AppLogger.error('Refresh printer realtime presence', error, stackTrace);
      }
    });
  }

  Future<void> stop() async {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    await _connectionSubscription?.cancel();
    await _signalSubscription?.cancel();
    _connectionSubscription = null;
    _signalSubscription = null;
    try {
      await _onDisconnect?.cancel();
      await _presence?.update(<String, Object?>{
        'online': false,
        'disconnectedAt': ServerValue.timestamp,
      });
    } on Object {
      // The armed server-side onDisconnect write remains the safe fallback.
    }
    _onDisconnect = null;
    _presence = null;
    _scope = null;
    _deviceId = null;
    final app = _app;
    _app = null;
    if (app != null) await FirebaseAuth.instanceFor(app: app).signOut();
  }
}
