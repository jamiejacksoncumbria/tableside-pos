import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class VenueHubPublicCredential {
  const VenueHubPublicCredential({
    required this.id,
    required this.deviceId,
    required this.publicKey,
  });

  final String id;
  final String deviceId;
  final SimplePublicKey publicKey;
}

class VenueHubBootstrap {
  const VenueHubBootstrap({
    required this.enabled,
    required this.hubEpoch,
    required this.credentials,
    required this.serverTimeMillis,
    this.hubDeviceId,
    this.hubCredentialId,
  });

  final bool enabled;
  final int hubEpoch;
  final String? hubDeviceId;
  final String? hubCredentialId;
  final Map<String, VenueHubPublicCredential> credentials;
  final int serverTimeMillis;

  factory VenueHubBootstrap.fromJson(Map<String, Object?> json) {
    final epoch = json['hubEpoch'];
    final serverTime = json['serverTimeMillis'];
    if (epoch is! int || epoch < 0 || serverTime is! int || serverTime <= 0) {
      throw const FormatException('The venue hub bootstrap is invalid.');
    }
    final credentials = <String, VenueHubPublicCredential>{};
    final rawCredentials = json['credentials'];
    if (rawCredentials is! List) {
      throw const FormatException('The venue hub credential list is invalid.');
    }
    for (final raw in rawCredentials) {
      if (raw is! Map || raw['algorithm'] != 'Ed25519') {
        throw const FormatException('A venue hub credential is invalid.');
      }
      final id = raw['credentialId'];
      final deviceId = raw['deviceId'];
      final encodedKey = raw['publicKeyBase64'];
      if (id is! String ||
          id.isEmpty ||
          deviceId is! String ||
          deviceId.isEmpty ||
          encodedKey is! String) {
        throw const FormatException('A venue hub credential is invalid.');
      }
      late List<int> keyBytes;
      try {
        keyBytes = base64Url.decode(encodedKey);
      } on FormatException {
        throw const FormatException('A venue hub public key is invalid.');
      }
      if (keyBytes.length != 32 || credentials.containsKey(id)) {
        throw const FormatException('A venue hub public key is invalid.');
      }
      credentials[id] = VenueHubPublicCredential(
        id: id,
        deviceId: deviceId,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      );
    }
    final enabled = json['enabled'] == true;
    final hubDeviceId = json['hubDeviceId'] as String?;
    final hubCredentialId = json['hubCredentialId'] as String?;
    if (enabled &&
        (epoch < 1 ||
            hubDeviceId?.isNotEmpty != true ||
            hubCredentialId?.isNotEmpty != true ||
            !credentials.containsKey(hubCredentialId))) {
      throw const FormatException(
        'The enabled venue hub does not have a valid authority credential.',
      );
    }
    return VenueHubBootstrap(
      enabled: enabled,
      hubEpoch: epoch,
      hubDeviceId: hubDeviceId,
      hubCredentialId: hubCredentialId,
      credentials: Map.unmodifiable(credentials),
      serverTimeMillis: serverTime,
    );
  }
}
