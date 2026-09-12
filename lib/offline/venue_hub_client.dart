import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/trusted_clock.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_protocol.dart';

class VenueHubClientConfiguration {
  const VenueHubClientConfiguration({
    required this.endpoint,
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
    required this.staffId,
    this.staffSessionId,
    this.staffSessionToken,
    required this.hubEpoch,
    required this.credential,
  });

  final Uri endpoint;
  final String tenantId;
  final String venueId;
  final String deviceId;
  final String staffId;
  final String? staffSessionId;
  final String? staffSessionToken;
  final int hubEpoch;
  final VenueHubDeviceCredential credential;
}

class VenueHubEventAcknowledgement {
  const VenueHubEventAcknowledgement({
    required this.eventId,
    required this.sequence,
    required this.eventHash,
    required this.committedAtUtc,
  });

  final String eventId;
  final int sequence;
  final String eventHash;
  final DateTime committedAtUtc;
}

class VenueHubLoginResult {
  const VenueHubLoginResult({
    required this.sessionId,
    required this.sessionToken,
    required this.staffId,
    required this.permissions,
    required this.expiresAtUtc,
  });

  final String sessionId;
  final String sessionToken;
  final String staffId;
  final Set<String> permissions;
  final DateTime expiresAtUtc;
}

class VenueHubClient {
  VenueHubClient({
    required this.configuration,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  }) : _http = httpClient ?? http.Client() {
    if (configuration.endpoint.scheme != 'https' ||
        configuration.endpoint.host.isEmpty) {
      throw ArgumentError.value(
        configuration.endpoint,
        'endpoint',
        'The venue hub must use a trusted HTTPS endpoint.',
      );
    }
    if (configuration.hubEpoch < 1) {
      throw ArgumentError.value(
        configuration.hubEpoch,
        'hubEpoch',
        'Must be positive.',
      );
    }
  }

  final VenueHubClientConfiguration configuration;
  final Duration timeout;
  final http.Client _http;

  Future<bool> isHealthy() async {
    final started = DateTime.now().toUtc();
    try {
      final response = await _http
          .get(configuration.endpoint.resolve('/v1/health'))
          .timeout(timeout);
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['status'] != 'ready') return false;
      final epoch = decoded['hubEpoch'];
      final serverTime = decoded['serverTimeMillis'];
      if (epoch != configuration.hubEpoch ||
          serverTime is! int ||
          serverTime <= 0) {
        return false;
      }
      TrustedClock.instance.acceptHubSample(
        hubTimeMillis: serverTime,
        requestStartedUtc: started,
        responseReceivedUtc: DateTime.now().toUtc(),
        hubEpoch: configuration.hubEpoch,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<VenueHubEventAcknowledgement> sendEvent({
    required String eventType,
    required Map<String, Object?> payload,
    DateTime? businessTimestampUtc,
  }) async {
    final sessionId = configuration.staffSessionId;
    final sessionToken = configuration.staffSessionToken;
    if (sessionId == null ||
        sessionId.isEmpty ||
        sessionToken == null ||
        sessionToken.length < 32) {
      throw const VenueHubClientException(
        'Enter a staff PIN before changing venue data.',
      );
    }
    final body = <String, Object?>{
      'staffSessionId': sessionId,
      'staffSessionToken': sessionToken,
      'eventType': eventType,
      'payload': payload,
      if (businessTimestampUtc != null)
        'businessTimestampUtc': businessTimestampUtc.toUtc().toIso8601String(),
    };
    final envelope =
        await VenueHubRequestSigner(configuration.credential.keyPair).sign(
          credentialId: configuration.credential.credentialId,
          tenantId: configuration.tenantId,
          venueId: configuration.venueId,
          deviceId: configuration.deviceId,
          staffId: configuration.staffId,
          method: 'POST',
          path: '/v1/events',
          hubEpoch: configuration.hubEpoch,
          sentAtUtc: TrustedClock.instance.nowUtc(),
          body: body,
        );
    final response = await _http
        .post(
          configuration.endpoint.resolve('/v1/events'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'envelope': envelope.toJson(), 'body': body}),
        )
        .timeout(timeout);
    if (response.statusCode != 201) {
      throw VenueHubClientException(
        response.statusCode == 401 || response.statusCode == 403
            ? 'The venue hub rejected this device or staff session.'
            : 'The venue hub could not safely save this operation.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['accepted'] != true) {
      throw const VenueHubClientException(
        'The venue hub returned an invalid acknowledgement.',
      );
    }
    final eventId = decoded['eventId'];
    final sequence = decoded['sequence'];
    final eventHash = decoded['eventHash'];
    final committedAt = decoded['committedAtUtc'];
    final parsedTime = committedAt is String
        ? DateTime.tryParse(committedAt)?.toUtc()
        : null;
    if (eventId is! String ||
        eventId.isEmpty ||
        sequence is! int ||
        sequence < 1 ||
        eventHash is! String ||
        eventHash.isEmpty ||
        parsedTime == null) {
      throw const VenueHubClientException(
        'The venue hub returned an invalid acknowledgement.',
      );
    }
    return VenueHubEventAcknowledgement(
      eventId: eventId,
      sequence: sequence,
      eventHash: eventHash,
      committedAtUtc: parsedTime,
    );
  }

  Future<VenueHubLoginResult> login(String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const VenueHubClientException('Enter a six-digit staff PIN.');
    }
    final body = <String, Object?>{'pin': pin};
    final envelope =
        await VenueHubRequestSigner(configuration.credential.keyPair).sign(
          credentialId: configuration.credential.credentialId,
          tenantId: configuration.tenantId,
          venueId: configuration.venueId,
          deviceId: configuration.deviceId,
          staffId: configuration.staffId,
          method: 'POST',
          path: '/v1/login',
          hubEpoch: configuration.hubEpoch,
          sentAtUtc: TrustedClock.instance.nowUtc(),
          body: body,
        );
    final response = await _http
        .post(
          configuration.endpoint.resolve('/v1/login'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'envelope': envelope.toJson(), 'body': body}),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw const VenueHubClientException(
        'The venue hub rejected the staff PIN.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const VenueHubClientException('The hub login response is invalid.');
    }
    final id = decoded['sessionId'];
    final token = decoded['sessionToken'];
    final staffId = decoded['staffId'];
    final permissions = decoded['permissions'];
    final expires = DateTime.tryParse(decoded['expiresAtUtc'] as String? ?? '');
    if (id is! String ||
        id.isEmpty ||
        token is! String ||
        token.length < 32 ||
        staffId != configuration.staffId ||
        permissions is! List ||
        expires == null) {
      throw const VenueHubClientException('The hub login response is invalid.');
    }
    return VenueHubLoginResult(
      sessionId: id,
      sessionToken: token,
      staffId: staffId as String,
      permissions: permissions.whereType<String>().toSet(),
      expiresAtUtc: expires.toUtc(),
    );
  }

  Future<Map<String, Object?>?> claimPrintJob() async {
    const body = <String, Object?>{};
    final response = await _signedPost('/v1/print/claim', body);
    if (response.statusCode != 200) {
      throw const VenueHubClientException(
        'The venue hub rejected this printer device.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const VenueHubClientException('The print response is invalid.');
    }
    final job = decoded['job'];
    return job is Map ? Map<String, Object?>.from(job) : null;
  }

  Future<Map<String, Object?>> fetchCatalogue() async {
    const body = <String, Object?>{};
    final response = await _signedPost('/v1/catalogue', body);
    if (response.statusCode != 200) {
      throw const VenueHubClientException(
        'The venue hub catalogue is unavailable.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['version'] is! int) {
      throw const VenueHubClientException(
        'The venue hub catalogue response is invalid.',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<List<Map<String, Object?>>> fetchOrders() async {
    final sessionId = configuration.staffSessionId;
    final sessionToken = configuration.staffSessionToken;
    if (sessionId == null || sessionToken == null) {
      throw const VenueHubClientException('A staff session is required.');
    }
    final body = <String, Object?>{
      'staffSessionId': sessionId,
      'staffSessionToken': sessionToken,
    };
    final response = await _signedPost('/v1/orders', body);
    if (response.statusCode != 200) {
      throw const VenueHubClientException('The hub orders are unavailable.');
    }
    final decoded = jsonDecode(response.body);
    final orders = decoded is Map ? decoded['orders'] : null;
    if (orders is! List) {
      throw const VenueHubClientException('The hub order response is invalid.');
    }
    return orders
        .whereType<Map>()
        .map((order) => Map<String, Object?>.from(order))
        .toList(growable: false);
  }

  Stream<List<Map<String, Object?>>> watchOrders() async* {
    yield await fetchOrders();
    final sessionId = configuration.staffSessionId;
    final sessionToken = configuration.staffSessionToken;
    if (sessionId == null || sessionToken == null) return;
    final body = <String, Object?>{
      'staffSessionId': sessionId,
      'staffSessionToken': sessionToken,
    };
    final envelope =
        await VenueHubRequestSigner(configuration.credential.keyPair).sign(
          credentialId: configuration.credential.credentialId,
          tenantId: configuration.tenantId,
          venueId: configuration.venueId,
          deviceId: configuration.deviceId,
          staffId: configuration.staffId,
          method: 'GET',
          path: '/v1/stream',
          hubEpoch: configuration.hubEpoch,
          sentAtUtc: TrustedClock.instance.nowUtc(),
          body: body,
        );
    final uri = configuration.endpoint
        .resolve('/v1/stream')
        .replace(
          scheme: configuration.endpoint.scheme == 'https' ? 'wss' : 'ws',
        );
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready.timeout(timeout);
      channel.sink.add(
        jsonEncode({'envelope': envelope.toJson(), 'body': body}),
      );
      await for (final raw in channel.stream) {
        if (raw is! String) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map || decoded['type'] != 'orders.changed') continue;
        final orders = decoded['orders'];
        if (orders is List) {
          yield orders
              .whereType<Map>()
              .map((order) => Map<String, Object?>.from(order))
              .toList(growable: false);
        }
      }
    } finally {
      await channel.sink.close();
    }
  }

  Future<void> completePrintJob({
    required String jobId,
    required bool printed,
    String? failureReason,
  }) async {
    final body = <String, Object?>{
      'jobId': jobId,
      'printed': printed,
      if (failureReason != null) 'failureReason': failureReason,
    };
    final response = await _signedPost('/v1/print/complete', body);
    if (response.statusCode != 200) {
      throw const VenueHubClientException(
        'The venue hub could not complete this print job.',
      );
    }
  }

  Future<http.Response> _signedPost(
    String path,
    Map<String, Object?> body,
  ) async {
    final envelope =
        await VenueHubRequestSigner(configuration.credential.keyPair).sign(
          credentialId: configuration.credential.credentialId,
          tenantId: configuration.tenantId,
          venueId: configuration.venueId,
          deviceId: configuration.deviceId,
          staffId: configuration.staffId,
          method: 'POST',
          path: path,
          hubEpoch: configuration.hubEpoch,
          sentAtUtc: TrustedClock.instance.nowUtc(),
          body: body,
        );
    return _http
        .post(
          configuration.endpoint.resolve(path),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'envelope': envelope.toJson(), 'body': body}),
        )
        .timeout(timeout);
  }

  void close() => _http.close();
}

class VenueHubClientException implements Exception {
  const VenueHubClientException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubClientException: $message';
}
