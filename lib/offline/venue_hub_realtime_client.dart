import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import 'transient_realtime_database.dart';
import 'venue_hub_availability.dart';

/// A staff-scoped realtime control channel for remote POS terminals.
///
/// RTDB carries only hub presence and command acknowledgement metadata. The
/// authenticated POS API remains responsible for validating and enqueueing
/// every mutation, and the hub remains responsible for the durable commit.
class VenueHubRealtimeClient {
  VenueHubRealtimeClient._();

  static final VenueHubRealtimeClient instance = VenueHubRealtimeClient._();
  static const _secondaryAppName = 'tableside-pos-realtime';
  static const _staleAfter = Duration(seconds: 15);

  VenueScope? _scope;
  int? _hubEpoch;
  FirebaseApp? _app;
  FirebaseDatabase? _database;
  StreamSubscription<DatabaseEvent>? _presenceSubscription;
  StreamSubscription<DatabaseEvent>? _printerPresenceSubscription;
  final StreamController<Map<String, DateTime>> _printerPresence =
      StreamController<Map<String, DateTime>>.broadcast();
  Timer? _staleTimer;
  DateTime? _lastReadyAt;
  bool _serverOnline = false;
  bool _ready = false;
  Future<void>? _configuration;
  final StreamController<bool> _availabilityChanges =
      StreamController<bool>.broadcast();

  bool isReadyFor(VenueScope scope, int hubEpoch) =>
      _ready &&
      _scope == scope &&
      _hubEpoch == hubEpoch &&
      _database != null;

  bool get hubOnline =>
      _serverOnline &&
      _lastReadyAt != null &&
      DateTime.now().difference(_lastReadyAt!) <= _staleAfter;

  Stream<Map<String, DateTime>> get printerPresence => _printerPresence.stream;

  /// Waits briefly for the first live presence event instead of declaring the
  /// hub offline while Firebase is still opening its realtime socket.
  ///
  /// Configuration and presence are intentionally separate states. A client
  /// can be authenticated and subscribed before the server has delivered the
  /// first value; treating that short interval as a failed configuration left
  /// the old implementation half-configured and unable to retry.
  Future<void> waitUntilHubOnline({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (hubOnline) return;
    try {
      await _availabilityChanges.stream
          .firstWhere((online) => online)
          .timeout(timeout);
    } on TimeoutException {
      throw StateError(
        'The venue hub realtime presence was not confirmed. Check that the '
        'hub is running and connected to the internet.',
      );
    }
  }

  Future<void> ensureConfigured({
    required VenueScope scope,
    required int hubEpoch,
    required ProductionCommandRepository repository,
  }) async {
    if (isReadyFor(scope, hubEpoch)) return;
    final current = _configuration;
    if (current != null) return current;
    final future = _configure(
      scope: scope,
      hubEpoch: hubEpoch,
      repository: repository,
    );
    _configuration = future;
    try {
      await future;
    } finally {
      if (identical(_configuration, future)) _configuration = null;
    }
  }

  Future<void> _configure({
    required VenueScope scope,
    required int hubEpoch,
    required ProductionCommandRepository repository,
  }) async {
    await _clearSession(markOffline: false);
    try {
      final session = await repository.issueRealtimePosSession(scope: scope);
      final token = session['customToken'];
      final databaseUrl = session['databaseUrl'];
      final deviceId = session['hubDeviceId'];
      final returnedEpoch = session['hubEpoch'];
      if (token is! String ||
          token.isEmpty ||
          databaseUrl is! String ||
          !databaseUrl.startsWith('https://') ||
          deviceId is! String ||
          deviceId.isEmpty ||
          returnedEpoch is! int ||
          returnedEpoch != hubEpoch) {
        throw StateError(
          'The server returned an invalid realtime POS session.',
        );
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
      await FirebaseAuth.instanceFor(app: app).signInWithCustomToken(token);
      final database = TransientRealtimeDatabase.instanceFor(
        app: app,
        databaseUrl: databaseUrl,
      );

      _scope = scope;
      _hubEpoch = hubEpoch;
      _app = app;
      _database = database;
      final presenceReference = database.ref(
        'hubPresence/${scope.tenantId}/${scope.venueId}/$deviceId',
      );
      void applyPresence(DataSnapshot snapshot) {
        final raw = snapshot.value;
        final value = raw is Map ? raw : const <Object?, Object?>{};
        final millis = value['lastReadyAt'];
        _serverOnline =
            value['online'] == true && value['hubEpoch'] == hubEpoch;
        _lastReadyAt = millis is int
            ? DateTime.fromMillisecondsSinceEpoch(millis)
            : null;
        _publishAvailability();
      }

      _presenceSubscription = presenceReference.onValue.listen(
        (event) => applyPresence(event.snapshot),
        onError: (Object error, StackTrace stackTrace) {
          _serverOnline = false;
          _publishAvailability(detail: error.toString());
          AppLogger.error(
            'Watch realtime venue hub presence',
            error,
            stackTrace,
          );
        },
      );
      _printerPresenceSubscription = database
          .ref('printerPresence/${scope.tenantId}/${scope.venueId}')
          .onValue
          .listen((event) {
            final result = <String, DateTime>{};
            final raw = event.snapshot.value;
            if (raw is Map) {
              for (final entry in raw.entries) {
                final value = entry.value;
                if (entry.key is! String ||
                    value is! Map ||
                    value['online'] != true) {
                  continue;
                }
                final millis = value['lastReadyAt'];
                if (millis is int) {
                  result[entry.key as String] =
                      DateTime.fromMillisecondsSinceEpoch(millis);
                }
              }
            }
            _printerPresence.add(result);
          });
      _staleTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _publishAvailability(),
      );
      _ready = true;
      _publishAvailability(
        detail: 'Connecting to the venue hub realtime channel…',
      );
    } on Object {
      // Never retain a partially configured database after authentication or
      // subscription setup fails. A later command can then retry cleanly.
      await _clearSession(markOffline: false);
      rethrow;
    }
  }

  void _publishAvailability({String? detail}) {
    final online = hubOnline;
    _availabilityChanges.add(online);
    if (online) {
      final wasOffline = VenueHubAvailability.issue.value != null;
      VenueHubAvailability.markOnline();
      if (wasOffline) AppLogger.info('Venue hub is back online and ready.');
      return;
    }
    VenueHubAvailability.markOffline(
      detail ?? 'The venue hub realtime presence is offline.',
    );
  }

  /// Waits on the caller-scoped RTDB acknowledgement written by the trusted
  /// backend. This replaces repeated HTTPS long-poll Functions calls.
  Future<Map<String, Object?>> waitForCommand(
    VenueScope scope,
    String commandId, {
    required Duration timeout,
  }) async {
    final database = _database;
    if (database == null || _scope != scope) {
      throw StateError('The realtime venue hub channel is not connected.');
    }
    final reference = database.ref(
      'remoteCommandStatus/${scope.tenantId}/${scope.venueId}/$commandId',
    );
    final event = await reference.onValue
        .firstWhere((event) {
          final raw = event.snapshot.value;
          if (raw is! Map) return false;
          return const {
            'accepted',
            'rejected',
            'expired',
          }.contains(raw['status']);
        })
        .timeout(timeout);
    final raw = event.snapshot.value;
    if (raw is! Map) {
      throw StateError('The venue hub returned an invalid acknowledgement.');
    }
    return Map<String, Object?>.from(raw);
  }

  Future<void> clear() => _clearSession(markOffline: false);

  Future<void> _clearSession({required bool markOffline}) async {
    _staleTimer?.cancel();
    _staleTimer = null;
    final presenceSubscription = _presenceSubscription;
    _presenceSubscription = null;
    final printerPresenceSubscription = _printerPresenceSubscription;
    _printerPresenceSubscription = null;
    final app = _app;
    _app = null;
    _ready = false;
    _scope = null;
    _hubEpoch = null;
    _database = null;
    _serverOnline = false;
    _lastReadyAt = null;
    _availabilityChanges.add(false);
    if (markOffline) VenueHubAvailability.markOffline();
    await presenceSubscription?.cancel();
    await printerPresenceSubscription?.cancel();
    if (app != null) {
      try {
        await FirebaseAuth.instanceFor(app: app).signOut();
      } on Object {
        // A short-lived scoped identity has no access outside this venue.
      }
    }
  }
}
