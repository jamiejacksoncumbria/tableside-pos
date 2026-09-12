import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class VenueHubSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureVenueHubSecretStore implements VenueHubSecretStore {
  const SecureVenueHubSecretStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class VenueHubDeviceCredential {
  const VenueHubDeviceCredential({
    required this.credentialId,
    required this.publicKeyBase64,
    required this.keyPair,
  });

  final String credentialId;
  final String publicKeyBase64;
  final KeyPair keyPair;
}

/// Generates a non-exported device signing seed and retains it in the OS
/// credential store. Firebase and the hub receive only its Ed25519 public key,
/// so neither can impersonate the physical device if Firestore is disclosed.
class VenueHubDeviceCredentialStore {
  VenueHubDeviceCredentialStore({VenueHubSecretStore? secrets})
    : _secrets = secrets ?? const SecureVenueHubSecretStore();

  static const _prefix = 'tableside.venueHub.ed25519.v1';
  final VenueHubSecretStore _secrets;
  final Ed25519 _algorithm = Ed25519();

  Future<VenueHubDeviceCredential> getOrCreate({
    required String tenantId,
    required String venueId,
    required String deviceId,
  }) async {
    _requireId('tenantId', tenantId);
    _requireId('venueId', venueId);
    _requireId('deviceId', deviceId);
    final storageKey = await _storageKey(tenantId, venueId, deviceId);
    final stored = await _secrets.read(storageKey);
    late List<int> seed;
    if (stored == null) {
      final random = Random.secure();
      seed = List<int>.generate(32, (_) => random.nextInt(256));
      await _secrets.write(storageKey, base64UrlEncode(seed));
    } else {
      try {
        seed = base64Url.decode(stored);
      } on FormatException {
        throw StateError('The venue hub device credential is corrupted.');
      }
      if (seed.length != 32) {
        throw StateError('The venue hub device credential is corrupted.');
      }
    }
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBase64 = base64UrlEncode(publicKey.bytes);
    final fingerprint = await Sha256().hash(publicKey.bytes);
    return VenueHubDeviceCredential(
      credentialId:
          'ed25519-${base64UrlEncode(fingerprint.bytes).substring(0, 22)}',
      publicKeyBase64: publicKeyBase64,
      keyPair: keyPair,
    );
  }

  Future<void> revokeLocal({
    required String tenantId,
    required String venueId,
    required String deviceId,
  }) async {
    await _secrets.delete(await _storageKey(tenantId, venueId, deviceId));
  }

  Future<String> _storageKey(
    String tenantId,
    String venueId,
    String deviceId,
  ) async {
    final digest = await Sha256().hash(
      utf8.encode('$tenantId\u0000$venueId\u0000$deviceId'),
    );
    return '$_prefix.${base64UrlEncode(digest.bytes)}';
  }
}

void _requireId(String name, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 160) {
    throw ArgumentError.value(value, name, 'Must contain 1–160 characters.');
  }
}
