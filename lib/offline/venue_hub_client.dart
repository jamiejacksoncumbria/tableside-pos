import 'dart:convert';

import 'package:http/http.dart' as http;

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
    required this.hubEpoch,
    required this.credential,
  });

  final Uri endpoint;
  final String tenantId;
  final String venueId;
  final String deviceId;
  final String staffId;
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
    try {
      final response = await _http
          .get(configuration.endpoint.resolve('/v1/health'))
          .timeout(timeout);
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['status'] != 'ready') return false;
      final epoch = decoded['hubEpoch'];
      final serverTime = decoded['serverTimeMillis'];
      return epoch == configuration.hubEpoch &&
          serverTime is int &&
          serverTime > 0;
    } catch (_) {
      return false;
    }
  }

  Future<VenueHubEventAcknowledgement> sendEvent({
    required String eventType,
    required Map<String, Object?> payload,
    DateTime? businessTimestampUtc,
  }) async {
    final body = <String, Object?>{
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

  void close() => _http.close();
}

class VenueHubClientException implements Exception {
  const VenueHubClientException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubClientException: $message';
}
