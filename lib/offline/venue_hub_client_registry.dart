import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../core/trusted_clock.dart';
import '../features/pos/domain.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_client.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_offline_view.dart';
import 'venue_hub_availability.dart';

/// Process-local routing authority for operational POS commands.
///
/// Once the cloud enables a venue hub, callers must use this client or fail
/// closed. They must never silently fall back to Cloud Functions because that
/// would permit two independent writers during an internet partition.
class VenueHubClientRegistry {
  VenueHubClientRegistry._();

  static final VenueHubClientRegistry instance = VenueHubClientRegistry._();
  static const _secrets = FlutterSecureStorage();

  VenueScope? _scope;
  VenueHubBootstrap? _bootstrap;
  VenueHubClient? _client;
  DateTime? _sessionExpiresAtUtc;
  bool _deviceEnrolled = false;
  bool _isLocalHubHost = false;
  String? _connectionFailure;
  StreamSubscription<List<Map<String, Object?>>>? _orderSubscription;
  Timer? _orderReconnectTimer;
  Timer? _healthTimer;
  bool _healthCheckRunning = false;
  bool _lanHealthy = false;
  int _streamGeneration = 0;
  final Set<String> _openedOrderIds = <String>{};
  DateTime? _lastOrderStreamFailureLoggedAt;
  final ValueNotifier<int> staffSessionInvalidations = ValueNotifier<int>(0);

  bool requiresHub(VenueScope scope) =>
      _scope == scope && _bootstrap?.enabled == true;

  bool isDeviceEnrolled(VenueScope scope) =>
      requiresHub(scope) && _deviceEnrolled;

  bool isLocalHubHost(VenueScope scope) =>
      requiresHub(scope) && _isLocalHubHost;

  String _unavailableMessage(VenueScope scope) {
    if (!isDeviceEnrolled(scope)) {
      return 'This device must be enrolled in Venue offline hub settings before it can process orders.';
    }
    if (_connectionFailure != null) {
      return 'The venue hub connection is unavailable. Check the trusted certificate in Venue offline hub settings.';
    }
    return 'The venue hub session is unavailable. Re-enter your staff PIN.';
  }

  bool hasUsableSession(VenueScope scope) =>
      requiresHub(scope) &&
      _lanHealthy &&
      _client != null &&
      _sessionExpiresAtUtc?.isAfter(TrustedClock.instance.nowUtc()) == true;

  VenueHubClient? clientFor(VenueScope scope) =>
      hasUsableSession(scope) ? _client : null;
  int? hubEpochFor(VenueScope scope) =>
      requiresHub(scope) ? _bootstrap?.hubEpoch : null;

  /// Returns the already-verified bootstrap held in memory. Offline settings
  /// screens use this read-only view instead of attempting a Firebase request.
  VenueHubBootstrap? bootstrapFor(VenueScope scope) =>
      _scope == scope ? _bootstrap : null;

  Future<void> refreshCatalogue(VenueScope scope) async {
    final client = clientFor(scope);
    if (client == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await client.refreshCatalogue();
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await client.refreshCatalogue();
    VenueHubOfflineView.instance.install(await client.fetchCatalogue());
  }

  /// Enrolled LAN clients poll only lightweight hub queue metadata. Physical
  /// claiming remains device-authenticated and manager recovery remains
  /// separately PIN-authorised; this stream merely makes delivery failures
  /// visible on every signed-in venue device.
  Stream<List<Map<String, Object?>>> watchPrintJobs(
    VenueScope scope, {
    Set<String>? statuses,
    DateTime? sinceUtc,
    int? limit,
  }) async* {
    while (hasUsableSession(scope)) {
      final client = clientFor(scope);
      if (client == null) return;
      try {
        yield await client.fetchPrintJobs(
          statuses: statuses,
          sinceUtc: sinceUtc,
          limit: limit,
        );
      } on Object catch (error) {
        if (_isInvalidStaffSession(error)) {
          _invalidateStaffSession();
          return;
        }
        rethrow;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> ensureOrderOpened({
    required VenueScope scope,
    required String orderId,
    String? tableId,
    String? tabName,
    OrderChannel channel = OrderChannel.dineIn,
    String? customerId,
    String? customerName,
    String? customerPhone,
    String? deliveryAddress,
    String? deliveryAddressLabel,
    double? deliveryLatitude,
    double? deliveryLongitude,
    String? serviceAreaId,
    String? serviceAreaName,
    int deliveryFeeMinor = 0,
    DateTime? scheduledFor,
    String? assignedDriverId,
    String? assignedDriverName,
  }) async {
    final client = clientFor(scope);
    if (client == null) {
      if (requiresHub(scope)) {
        throw StateError(_unavailableMessage(scope));
      }
      return;
    }
    if (_openedOrderIds.contains(orderId)) return;
    try {
      await client.sendEvent(
        eventType: 'order.opened',
        payload: <String, Object?>{
          'orderId': orderId,
          if (tableId?.trim().isNotEmpty == true) 'tableId': tableId!.trim(),
          if (tabName?.trim().isNotEmpty == true) 'tabName': tabName!.trim(),
          'channel': channel.name,
          if (customerId?.trim().isNotEmpty == true)
            'customerId': customerId!.trim(),
          if (customerName?.trim().isNotEmpty == true)
            'customerName': customerName!.trim(),
          if (customerPhone?.trim().isNotEmpty == true)
            'customerPhone': customerPhone!.trim(),
          if (deliveryAddress?.trim().isNotEmpty == true)
            'deliveryAddress': deliveryAddress!.trim(),
          if (deliveryAddressLabel?.trim().isNotEmpty == true)
            'deliveryAddressLabel': deliveryAddressLabel!.trim(),
          'deliveryLatitude': ?deliveryLatitude,
          'deliveryLongitude': ?deliveryLongitude,
          if (serviceAreaId?.trim().isNotEmpty == true)
            'serviceAreaId': serviceAreaId!.trim(),
          if (serviceAreaName?.trim().isNotEmpty == true)
            'serviceAreaName': serviceAreaName!.trim(),
          if (channel == OrderChannel.delivery)
            'deliveryFeeMinor': deliveryFeeMinor,
          if (scheduledFor != null)
            'scheduledForUtc': scheduledFor.toUtc().toIso8601String(),
          if (assignedDriverId?.trim().isNotEmpty == true)
            'assignedDriverId': assignedDriverId!.trim(),
          if (assignedDriverName?.trim().isNotEmpty == true)
            'assignedDriverName': assignedDriverName!.trim(),
        },
      );
    } on Object catch (error) {
      if (_isInvalidStaffSession(error)) {
        _invalidateStaffSession();
      } else {
        _recordLanFailureIfTransport(error);
      }
      rethrow;
    }
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
            ? _unavailableMessage(scope)
            : 'Offline hub routing is not enabled for this venue.',
      );
    }
    try {
      return await client.sendEvent(
        eventType: eventType,
        payload: payload,
        businessTimestampUtc: businessTimestampUtc,
      );
    } on Object catch (error) {
      if (_isInvalidStaffSession(error)) {
        _invalidateStaffSession();
      } else {
        _recordLanFailureIfTransport(error);
      }
      rethrow;
    }
  }

  Future<VenueHubLoginResult?> configure({
    required VenueScope scope,
    required VenueHubBootstrap bootstrap,
    required String deviceId,
    required String staffId,
    required String pin,
    required VenueHubDeviceCredential credential,
    Uri? endpointOverride,
  }) async {
    clear();
    VenueHubAvailability.markChecking('Checking the venue hub…');
    _scope = scope;
    _bootstrap = bootstrap;
    if (!bootstrap.enabled) {
      VenueHubAvailability.reset();
      return null;
    }
    _isLocalHubHost =
        bootstrap.hubDeviceId == deviceId &&
        bootstrap.hubCredentialId == credential.credentialId;
    final endpoint = endpointOverride ?? bootstrap.endpoint;
    if (endpoint == null) {
      VenueHubAvailability.markOffline(
        'The venue hub endpoint is not configured.',
      );
      throw StateError('The venue hub endpoint is not configured.');
    }
    final enrolled = bootstrap.credentials[credential.credentialId];
    if (enrolled == null || enrolled.deviceId != deviceId) {
      // Cloud PIN verification may still unlock an online manager so this
      // device can be enrolled from Settings. Operational commands remain
      // fail-closed because requiresHub(scope) stays true and no hub client is
      // installed.
      AppLogger.info(
        'This device is online-only until a manager enrols it with the venue hub.',
      );
      VenueHubAvailability.markOffline(
        'This device is not enrolled with the venue hub. Orders are blocked.',
      );
      return null;
    }
    final trustedCertificate = await _secrets.read(
      key: _venueCertificateKey(scope),
    );
    if (trustedCertificate?.trim().isNotEmpty != true) {
      VenueHubAvailability.markOffline(
        'This device has no pinned venue certificate. Orders are blocked.',
      );
      throw StateError(
        'This device is enrolled but has no pinned venue certificate. '
        'Import the public venue certificate before using the LAN hub.',
      );
    }
    // A native terminal is operationally enrolled only when both its signing
    // credential is authorised by the server and its venue certificate is
    // pinned locally. This flag also gates the protected remote queue.
    _deviceEnrolled = true;
    final loginClient = VenueHubClient(
      configuration: VenueHubClientConfiguration(
        endpoint: endpoint,
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        deviceId: deviceId,
        staffId: staffId,
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
        trustedCertificatePem: trustedCertificate,
      ),
    );
    try {
      if (!await loginClient.isHealthy()) {
        throw StateError(
          loginClient.lastHealthFailure ??
              'The venue hub is unavailable on the local network.',
        );
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
          trustedCertificatePem: trustedCertificate,
        ),
        timeout: const Duration(seconds: 2),
      );
      _sessionExpiresAtUtc = login.expiresAtUtc;
      VenueHubOfflineView.instance.install(await _client!.fetchCatalogue());
      if (_isLocalHubHost) {
        // Runtime startup reconstructs every order from the encrypted ledger,
        // but `configure` first clears the preceding PIN session and its
        // in-memory view. Restore one authoritative snapshot immediately after
        // login. The host still avoids a redundant long-lived localhost
        // stream; subsequent durable commits publish directly from runtime.
        VenueHubOfflineView.instance.installOrders(
          await _client!.fetchOrders(),
        );
      }
      _lanHealthy = true;
      _startLanHealthMonitor();
      // The hub host publishes its authoritative order book directly into the
      // offline view after every durable commit. Opening a second HTTPS order
      // stream back to localhost is redundant and can race the listener during
      // cold startup. Enrolled terminals still use the authenticated stream.
      if (!_isLocalHubHost) _startOrderStream();
      VenueHubAvailability.markLanOnline();
      return login;
    } catch (error) {
      loginClient.close();
      _connectionFailure = error.toString();
      _clearSession(preserveAuthority: true);
      VenueHubAvailability.markOffline(error.toString());
      rethrow;
    }
  }

  void rememberBootstrap(VenueScope scope, VenueHubBootstrap bootstrap) {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
  }

  void clear() {
    _clearSession(preserveAuthority: false);
  }

  void _clearSession({required bool preserveAuthority}) {
    _streamGeneration++;
    _orderReconnectTimer?.cancel();
    _orderReconnectTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthCheckRunning = false;
    _lanHealthy = false;
    unawaited(_orderSubscription?.cancel());
    _orderSubscription = null;
    _client?.close();
    _client = null;
    if (!preserveAuthority) {
      _scope = null;
      _bootstrap = null;
      _deviceEnrolled = false;
      _isLocalHubHost = false;
      _connectionFailure = null;
    }
    _sessionExpiresAtUtc = null;
    _openedOrderIds.clear();
    VenueHubOfflineView.instance.clear();
  }

  void _startLanHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final client = _client;
      if (client == null || _healthCheckRunning) return;
      _healthCheckRunning = true;
      try {
        final healthy = await client.isHealthy();
        if (healthy) {
          final recovered = !_lanHealthy;
          _lanHealthy = true;
          VenueHubAvailability.markLanOnline();
          if (recovered) {
            AppLogger.info('Venue hub LAN connection is back online.');
          }
        } else {
          _recordLanFailure(
            StateError(
              client.lastHealthFailure ?? 'The venue hub did not respond.',
            ),
          );
        }
      } finally {
        _healthCheckRunning = false;
      }
    });
  }

  void _recordLanFailure(Object error) {
    _lanHealthy = false;
    VenueHubAvailability.markOffline(error.toString());
  }

  /// Business validation errors (for example an invalid modifier) prove that
  /// the hub answered and must not turn the terminal's connection indicator
  /// red. Only transport failures invalidate the live LAN health state.
  void _recordLanFailureIfTransport(Object error) {
    if (error is TimeoutException) {
      _recordLanFailure(error);
      return;
    }
    final message = error.toString().toLowerCase();
    if (const <String>[
      'socketexception',
      'clientexception',
      'connection refused',
      'connection reset',
      'connection closed',
      'network is unreachable',
      'failed host lookup',
      'timed out',
      'timeout',
    ].any(message.contains)) {
      _recordLanFailure(error);
    }
  }

  bool _isInvalidStaffSession(Object error) =>
      error is VenueHubClientException &&
      (error.code == 'staff_session_invalid' ||
          error.code == 'staff_session_required');

  void _invalidateStaffSession() {
    if (_client == null) return;
    AppLogger.info(
      'Venue hub rejected the expired or revoked staff session; locking this terminal for a fresh PIN.',
    );
    _clearSession(preserveAuthority: true);
    VenueHubAvailability.markOffline(
      'Your staff session ended. Enter your PIN again to continue.',
    );
    staffSessionInvalidations.value++;
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
        if (_isInvalidStaffSession(error)) {
          _invalidateStaffSession();
          return;
        }
        _recordLanFailureIfTransport(error);
        final now = DateTime.now();
        final lastLoggedAt = _lastOrderStreamFailureLoggedAt;
        if (lastLoggedAt == null ||
            now.difference(lastLoggedAt) >= const Duration(seconds: 30)) {
          _lastOrderStreamFailureLoggedAt = now;
          AppLogger.info(
            'Venue hub order stream is temporarily unavailable; retrying over LAN. ($error)',
          );
        }
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
  static const _secrets = FlutterSecureStorage();

  VenueScope? _scope;
  VenueHubBootstrap? _bootstrap;
  VenueHubClient? _client;
  bool _clockReady = false;
  bool _localHubHost = false;

  bool requiresHub(VenueScope scope) =>
      _scope == scope && _bootstrap?.enabled == true;

  bool isDeviceEnrolled(VenueScope scope) =>
      requiresHub(scope) && _client != null;

  /// Whether this process owns the authoritative hub for [scope].
  ///
  /// Printer polling uses this to avoid treating the short HTTPS listener
  /// startup window as a failed ticket. Remote printer devices must still
  /// fail quickly when the actual hub cannot be reached.
  bool isLocalHubHost(VenueScope scope) => requiresHub(scope) && _localHubHost;

  Future<void> configure({
    required VenueScope scope,
    required VenueHubBootstrap bootstrap,
    required String deviceId,
    required VenueHubDeviceCredential credential,
    Uri? endpointOverride,
  }) async {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
    _localHubHost =
        bootstrap.hubDeviceId == deviceId &&
        bootstrap.hubCredentialId == credential.credentialId;
    if (!bootstrap.enabled) return;
    final endpoint = endpointOverride ?? bootstrap.endpoint;
    final enrolled = bootstrap.credentials[credential.credentialId];
    if (endpoint == null || enrolled?.deviceId != deviceId) return;
    final trustedCertificate = await _secrets.read(
      key: _venueCertificateKey(scope),
    );
    if (trustedCertificate?.trim().isNotEmpty != true) {
      // Printer claiming must never fall back to Android/Windows trust roots.
      // It carries operational authority even while no member of staff is
      // signed in, so absence of the venue pin is a hard failure.
      return;
    }
    _client = VenueHubClient(
      configuration: VenueHubClientConfiguration(
        endpoint: endpoint,
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        deviceId: deviceId,
        staffId: 'printer-device',
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
        trustedCertificatePem: trustedCertificate,
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
        throw StateError(
          client.lastHealthFailure ??
              'The venue hub is unavailable on the local network.',
        );
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
    _localHubHost = false;
  }
}

String _venueCertificateKey(VenueScope scope) =>
    'tableside.offlineHub.tls.${scope.tenantId}.${scope.venueId}.certificate';
