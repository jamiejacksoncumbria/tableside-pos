import 'dart:async';

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
  int _streamGeneration = 0;
  final Set<String> _openedOrderIds = <String>{};

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
      _client != null &&
      _sessionExpiresAtUtc?.isAfter(TrustedClock.instance.nowUtc()) == true;

  VenueHubClient? clientFor(VenueScope scope) =>
      hasUsableSession(scope) ? _client : null;
  int? hubEpochFor(VenueScope scope) =>
      requiresHub(scope) ? _bootstrap?.hubEpoch : null;

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
  Stream<List<Map<String, Object?>>> watchPrintJobs(VenueScope scope) async* {
    while (hasUsableSession(scope)) {
      final client = clientFor(scope);
      if (client == null) return;
      yield await client.fetchPrintJobs();
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
        if (deliveryLatitude != null) 'deliveryLatitude': deliveryLatitude,
        if (deliveryLongitude != null) 'deliveryLongitude': deliveryLongitude,
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
    Uri? endpointOverride,
  }) async {
    clear();
    _scope = scope;
    _bootstrap = bootstrap;
    if (!bootstrap.enabled) return null;
    _isLocalHubHost =
        bootstrap.hubDeviceId == deviceId &&
        bootstrap.hubCredentialId == credential.credentialId;
    final endpoint = endpointOverride ?? bootstrap.endpoint;
    if (endpoint == null) {
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
      return null;
    }
    _deviceEnrolled = true;
    final trustedCertificate = await _secrets.read(
      key: _venueCertificateKey(scope),
    );
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
      );
      _sessionExpiresAtUtc = login.expiresAtUtc;
      VenueHubOfflineView.instance.install(await _client!.fetchCatalogue());
      _startOrderStream();
      VenueHubAvailability.markOnline();
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
  static const _secrets = FlutterSecureStorage();

  VenueScope? _scope;
  VenueHubBootstrap? _bootstrap;
  VenueHubClient? _client;
  bool _clockReady = false;

  bool requiresHub(VenueScope scope) =>
      _scope == scope && _bootstrap?.enabled == true;

  bool isDeviceEnrolled(VenueScope scope) =>
      requiresHub(scope) && _client != null;

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
    if (!bootstrap.enabled) return;
    final endpoint = endpointOverride ?? bootstrap.endpoint;
    final enrolled = bootstrap.credentials[credential.credentialId];
    if (endpoint == null || enrolled?.deviceId != deviceId) return;
    final trustedCertificate = await _secrets.read(
      key: _venueCertificateKey(scope),
    );
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
  }
}

String _venueCertificateKey(VenueScope scope) =>
    'tableside.offlineHub.tls.${scope.tenantId}.${scope.venueId}.certificate';
