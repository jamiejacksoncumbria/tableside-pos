import 'dart:async';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../core/trusted_clock.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_client.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_offline_view.dart';

/// Process-local routing authority for operational POS commands.
///
/// Once the cloud enables a venue hub, callers must use this client or fail
/// closed. They must never silently fall back to Cloud Functions because that
/// would permit two independent writers during an internet partition.
class VenueHubClientRegistry {
  VenueHubClientRegistry._();

  static final VenueHubClientRegistry instance = VenueHubClientRegistry._();

  VenueScope? _scope;
  VenueHubBootstrap? _bootstrap;
  VenueHubClient? _client;
  DateTime? _sessionExpiresAtUtc;
  StreamSubscription<List<Map<String, Object?>>>? _orderSubscription;
  Timer? _orderReconnectTimer;
  int _streamGeneration = 0;
  final Set<String> _openedOrderIds = <String>{};

  bool requiresHub(VenueScope scope) =>
      _scope == scope && _bootstrap?.enabled == true;

  bool hasUsableSession(VenueScope scope) =>
      requiresHub(scope) &&
      _client != null &&
      _sessionExpiresAtUtc?.isAfter(TrustedClock.instance.nowUtc()) == true;

  VenueHubClient? clientFor(VenueScope scope) =>
      hasUsableSession(scope) ? _client : null;
  int? hubEpochFor(VenueScope scope) =>
      requiresHub(scope) ? _bootstrap?.hubEpoch : null;

  Future<void> ensureOrderOpened({
    required VenueScope scope,
    required String orderId,
    String? tableId,
    String? tabName,
  }) async {
    final client = clientFor(scope);
    if (client == null) {
      if (requiresHub(scope)) {
        throw StateError(
          'The venue hub session is unavailable. Re-enter your staff PIN.',
        );
      }
      return;
    }
    if (_openedOrderIds.contains(orderId)) return;
    await client.sendEvent(
      eventType: 'order.opened',
      payload: <String, Object?>{
        'orderId': orderId,
        if (tableId?.trim().isNotEmpty == true) 'tableId': tableId!.trim(),
        if (tabName?.trim().isNotEmpty == true) 'tabName': tabName!.trim(),
      },
    );
    _openedOrderIds.add(orderId);
  }

  Future<VenueHubEventAcknowledgement> send({
    required VenueScope scope,
    required String eventType,
    required Map<String, Object?> payload,
    DateTime? businessTimestampUtc,
  }) async {
    final client = clientFor(scope);
    if (client == null) {
      throw StateError(
        requiresHub(scope)
            ? 'The venue hub session is unavailable. Re-enter your staff PIN.'
            : 'Offline hub routing is not enabled for this venue.',
      );
    }
    return client.sendEvent(
      eventType: eventType,
      payload: payload,
      businessTimestampUtc: businessTimestampUtc,
    );
  }

  Future<VenueHubLoginResult?> configure({
    required VenueScope scope,
    required VenueHubBootstrap bootstrap,
    required String deviceId,
    required String staffId,
    required String pin,
    required VenueHubDeviceCredential credential,
  }) async {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
    if (!bootstrap.enabled) return null;
    final endpoint = bootstrap.endpoint;
    if (endpoint == null) {
      throw StateError('The venue hub endpoint is not configured.');
    }
    final enrolled = bootstrap.credentials[credential.credentialId];
    if (enrolled == null || enrolled.deviceId != deviceId) {
      throw StateError(
        'This device is not enrolled for offline use at this venue. '
        'Ask a manager to enrol it in Venue offline hub settings.',
      );
    }
    final loginClient = VenueHubClient(
      configuration: VenueHubClientConfiguration(
        endpoint: endpoint,
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        deviceId: deviceId,
        staffId: staffId,
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
      ),
    );
    try {
      if (!await loginClient.isHealthy()) {
        throw StateError('The venue hub is unavailable on the local network.');
      }
      final login = await loginClient.login(pin);
      loginClient.close();
      _client = VenueHubClient(
        configuration: VenueHubClientConfiguration(
          endpoint: endpoint,
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          deviceId: deviceId,
          staffId: staffId,
          staffSessionId: login.sessionId,
          staffSessionToken: login.sessionToken,
          hubEpoch: bootstrap.hubEpoch,
          credential: credential,
        ),
      );
      _sessionExpiresAtUtc = login.expiresAtUtc;
      VenueHubOfflineView.instance.install(await _client!.fetchCatalogue());
      _startOrderStream();
      return login;
    } catch (_) {
      loginClient.close();
      clear();
      rethrow;
    }
  }

  void rememberBootstrap(VenueScope scope, VenueHubBootstrap bootstrap) {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
  }

  void clear() {
    _streamGeneration++;
    _orderReconnectTimer?.cancel();
    _orderReconnectTimer = null;
    unawaited(_orderSubscription?.cancel());
    _orderSubscription = null;
    _client?.close();
    _client = null;
    _scope = null;
    _bootstrap = null;
    _sessionExpiresAtUtc = null;
    _openedOrderIds.clear();
    VenueHubOfflineView.instance.clear();
  }

  void _startOrderStream() {
    final client = _client;
    if (client == null) return;
    final generation = ++_streamGeneration;
    var scheduled = false;
    void reconnect() {
      if (scheduled || generation != _streamGeneration || _client == null) {
        return;
      }
      scheduled = true;
      _orderReconnectTimer?.cancel();
      _orderReconnectTimer = Timer(const Duration(seconds: 2), () {
        if (generation == _streamGeneration && _client != null) {
          _startOrderStream();
        }
      });
    }

    unawaited(_orderSubscription?.cancel());
    _orderSubscription = client.watchOrders().listen(
      VenueHubOfflineView.instance.installOrders,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error('Watch venue hub orders', error, stackTrace);
        reconnect();
      },
      onDone: reconnect,
      cancelOnError: true,
    );
  }
}

/// Device-scoped print route deliberately survives staff PIN locking. The
/// Ed25519 key proves the physical device and can only claim jobs addressed to
/// that device; it grants no order, payment, report, or administration access.
class VenueHubPrinterClientRegistry {
  VenueHubPrinterClientRegistry._();

  static final VenueHubPrinterClientRegistry instance =
      VenueHubPrinterClientRegistry._();

  VenueScope? _scope;
  VenueHubBootstrap? _bootstrap;
  VenueHubClient? _client;
  bool _clockReady = false;

  bool requiresHub(VenueScope scope) =>
      _scope == scope && _bootstrap?.enabled == true;

  void configure({
    required VenueScope scope,
    required VenueHubBootstrap bootstrap,
    required String deviceId,
    required VenueHubDeviceCredential credential,
  }) {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
    if (!bootstrap.enabled) return;
    final endpoint = bootstrap.endpoint;
    final enrolled = bootstrap.credentials[credential.credentialId];
    if (endpoint == null || enrolled?.deviceId != deviceId) return;
    _client = VenueHubClient(
      configuration: VenueHubClientConfiguration(
        endpoint: endpoint,
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        deviceId: deviceId,
        staffId: 'printer-device',
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
      ),
    );
  }

  Future<Map<String, Object?>?> claim(VenueScope scope) async {
    final client = _client;
    if (client == null || !requiresHub(scope)) {
      throw StateError('This printer is not enrolled with the venue hub.');
    }
    if (!_clockReady) {
      _clockReady = await client.isHealthy();
      if (!_clockReady) {
        throw StateError('The venue hub is unavailable on the local network.');
      }
    }
    return client.claimPrintJob();
  }

  Future<void> complete({
    required VenueScope scope,
    required String jobId,
    required bool printed,
    String? failureReason,
  }) {
    final client = _client;
    if (client == null || !requiresHub(scope)) {
      throw StateError('This printer is not enrolled with the venue hub.');
    }
    return client.completePrintJob(
      jobId: jobId,
      printed: printed,
      failureReason: failureReason,
    );
  }

  void clear() {
    _clockReady = false;
    _client?.close();
    _client = null;
    _scope = null;
    _bootstrap = null;
  }
}
