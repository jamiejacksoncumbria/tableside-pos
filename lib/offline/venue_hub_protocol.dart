import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class VenueHubRequestEnvelope {
  const VenueHubRequestEnvelope({
    required this.credentialId,
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
    required this.staffId,
    required this.method,
    required this.path,
    required this.hubEpoch,
    required this.sentAtUtcMillis,
    required this.nonce,
    required this.bodyHash,
    required this.signature,
  });

  final String credentialId;
  final String tenantId;
  final String venueId;
  final String deviceId;
  final String staffId;
  final String method;
  final String path;
  final int hubEpoch;
  final int sentAtUtcMillis;
  final String nonce;
  final String bodyHash;
  final String signature;

  Map<String, Object?> toJson() => {
    'credentialId': credentialId,
    'tenantId': tenantId,
    'venueId': venueId,
    'deviceId': deviceId,
    'staffId': staffId,
    'method': method,
    'path': path,
    'hubEpoch': hubEpoch,
    'sentAtUtcMillis': sentAtUtcMillis,
    'nonce': nonce,
    'bodyHash': bodyHash,
    'signature': signature,
  };

  factory VenueHubRequestEnvelope.fromJson(Map<String, Object?> json) {
    String text(String key, {int maximum = 256}) {
      final value = json[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > maximum ||
          value.contains('\n')) {
        throw const VenueHubProtocolException(
          'The signed request envelope is invalid.',
        );
      }
      return value;
    }

    final epoch = json['hubEpoch'];
    final sentAt = json['sentAtUtcMillis'];
    if (epoch is! int || epoch < 1 || sentAt is! int || sentAt <= 0) {
      throw const VenueHubProtocolException(
        'The signed request envelope is invalid.',
      );
    }
    return VenueHubRequestEnvelope(
      credentialId: text('credentialId'),
      tenantId: text('tenantId'),
      venueId: text('venueId'),
      deviceId: text('deviceId'),
      staffId: text('staffId'),
      method: text('method', maximum: 12).toUpperCase(),
      path: text('path', maximum: 128),
      hubEpoch: epoch,
      sentAtUtcMillis: sentAt,
      nonce: text('nonce', maximum: 128),
      bodyHash: text('bodyHash', maximum: 128),
      signature: text('signature', maximum: 256),
    );
  }

  String get canonicalHeaders => [
    'v1',
    credentialId,
    tenantId,
    venueId,
    deviceId,
    staffId,
    method.toUpperCase(),
    path,
    hubEpoch,
    sentAtUtcMillis,
    nonce,
    bodyHash,
  ].join('\n');
}

class VenueHubRequestSigner {
  VenueHubRequestSigner(this._credentialKeyPair);

  final KeyPair _credentialKeyPair;
  final Ed25519 _signatureAlgorithm = Ed25519();
  final Sha256 _sha256 = Sha256();

  Future<VenueHubRequestEnvelope> sign({
    required String credentialId,
    required String tenantId,
    required String venueId,
    required String deviceId,
    required String staffId,
    required String method,
    required String path,
    required int hubEpoch,
    required DateTime sentAtUtc,
    required Map<String, Object?> body,
    String? nonce,
  }) async {
    for (final entry in {
      'credentialId': credentialId,
      'tenantId': tenantId,
      'venueId': venueId,
      'deviceId': deviceId,
      'staffId': staffId,
      'method': method,
      'path': path,
    }.entries) {
      _requireText(entry.key, entry.value);
    }
    if (hubEpoch < 1) {
      throw ArgumentError.value(hubEpoch, 'hubEpoch', 'Must be positive.');
    }
    final safeNonce = nonce ?? _newNonce();
    _requireText('nonce', safeNonce);
    final bodyHash = base64UrlEncode(
      (await _sha256.hash(utf8.encode(_canonicalJson(body)))).bytes,
    );
    final unsigned = VenueHubRequestEnvelope(
      credentialId: credentialId,
      tenantId: tenantId,
      venueId: venueId,
      deviceId: deviceId,
      staffId: staffId,
      method: method.toUpperCase(),
      path: path,
      hubEpoch: hubEpoch,
      sentAtUtcMillis: sentAtUtc.toUtc().millisecondsSinceEpoch,
      nonce: safeNonce,
      bodyHash: bodyHash,
      signature: '',
    );
    final signature = await _signatureAlgorithm.sign(
      utf8.encode(unsigned.canonicalHeaders),
      keyPair: _credentialKeyPair,
    );
    return VenueHubRequestEnvelope(
      credentialId: unsigned.credentialId,
      tenantId: unsigned.tenantId,
      venueId: unsigned.venueId,
      deviceId: unsigned.deviceId,
      staffId: unsigned.staffId,
      method: unsigned.method,
      path: unsigned.path,
      hubEpoch: unsigned.hubEpoch,
      sentAtUtcMillis: unsigned.sentAtUtcMillis,
      nonce: unsigned.nonce,
      bodyHash: unsigned.bodyHash,
      signature: base64UrlEncode(signature.bytes),
    );
  }

  String _newNonce() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
  }
}

class VenueHubReplayGuard {
  VenueHubReplayGuard({this.maximumAge = const Duration(minutes: 2)});

  final Duration maximumAge;
  final Map<String, int> _acceptedNonces = <String, int>{};

  Future<void> verify({
    required VenueHubRequestEnvelope envelope,
    required Map<String, Object?> body,
    required PublicKey credentialPublicKey,
    required String expectedTenantId,
    required String expectedVenueId,
    required int expectedHubEpoch,
    required DateTime trustedNowUtc,
  }) async {
    if (envelope.tenantId != expectedTenantId ||
        envelope.venueId != expectedVenueId) {
      throw const VenueHubProtocolException(
        'The request is outside this hub tenant or venue.',
      );
    }
    if (envelope.hubEpoch != expectedHubEpoch) {
      throw const VenueHubProtocolException(
        'The request belongs to a stale hub generation.',
      );
    }
    final requestTime = DateTime.fromMillisecondsSinceEpoch(
      envelope.sentAtUtcMillis,
      isUtc: true,
    );
    final age = trustedNowUtc.toUtc().difference(requestTime).abs();
    if (age > maximumAge) {
      throw const VenueHubProtocolException(
        'The signed request timestamp is outside the allowed window.',
      );
    }
    final expectedBodyHash = base64UrlEncode(
      (await Sha256().hash(utf8.encode(_canonicalJson(body)))).bytes,
    );
    if (!_constantTimeEquals(expectedBodyHash, envelope.bodyHash)) {
      throw const VenueHubProtocolException(
        'The signed request body has been modified.',
      );
    }
    List<int> suppliedSignature;
    try {
      suppliedSignature = base64Url.decode(envelope.signature);
    } on FormatException {
      throw const VenueHubProtocolException(
        'The request signature is invalid.',
      );
    }
    final validSignature = await Ed25519().verify(
      utf8.encode(envelope.canonicalHeaders),
      signature: Signature(suppliedSignature, publicKey: credentialPublicKey),
    );
    if (!validSignature) {
      throw const VenueHubProtocolException(
        'The request signature is invalid.',
      );
    }

    final nowMillis = trustedNowUtc.toUtc().millisecondsSinceEpoch;
    _acceptedNonces.removeWhere(
      (_, acceptedAt) => nowMillis - acceptedAt > maximumAge.inMilliseconds,
    );
    final replayKey = '${envelope.credentialId}:${envelope.nonce}';
    if (_acceptedNonces.containsKey(replayKey)) {
      throw const VenueHubProtocolException(
        'The signed request nonce has already been used.',
      );
    }
    _acceptedNonces[replayKey] = nowMillis;
  }
}

class VenueHubProtocolException implements Exception {
  const VenueHubProtocolException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubProtocolException: $message';
}

String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalValue(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalValue).toList(growable: false);
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw ArgumentError.value(value, 'body', 'Contains an unsupported value.');
}

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final leftByte = index < a.length ? a[index] : 0;
    final rightByte = index < b.length ? b[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

void _requireText(String name, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 256 || trimmed.contains('\n')) {
    throw ArgumentError.value(value, name, 'Contains an invalid value.');
  }
}
