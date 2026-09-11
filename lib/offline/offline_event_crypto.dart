import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class EncryptedOfflineEnvelope {
  const EncryptedOfflineEnvelope({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;
}

/// Keeps a unique installation master key in the platform credential store
/// and encrypts every event body before it is written to SQLite.
class OfflineEventCrypto {
  OfflineEventCrypto({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  OfflineEventCrypto.forTesting(Uint8List masterKey)
    : _secureStorage = null,
      _masterKey = Uint8List.fromList(masterKey) {
    if (masterKey.length != _keyBytes) {
      throw ArgumentError.value(
        masterKey.length,
        'masterKey',
        'The test key must contain exactly $_keyBytes bytes.',
      );
    }
  }

  static const _masterKeyName = 'tableside.offlineEventMasterKey.v1';
  static const _keyBytes = 64;

  final FlutterSecureStorage? _secureStorage;
  final AesGcm _cipher = AesGcm.with256bits();
  final Hmac _hmac = Hmac.sha256();
  Uint8List? _masterKey;

  Future<void> initialize() async {
    if (_masterKey != null) return;
    final stored = await _secureStorage!.read(key: _masterKeyName);
    if (stored != null) {
      final decoded = base64Url.decode(stored);
      if (decoded.length != _keyBytes) {
        throw StateError('The offline storage key is invalid.');
      }
      _masterKey = Uint8List.fromList(decoded);
      return;
    }
    final random = Random.secure();
    final generated = Uint8List.fromList(
      List<int>.generate(_keyBytes, (_) => random.nextInt(256)),
    );
    await _secureStorage.write(
      key: _masterKeyName,
      value: base64UrlEncode(generated),
    );
    _masterKey = generated;
  }

  Future<String> venueKey(String tenantId, String venueId) async =>
      _macString('venue\u0000$tenantId\u0000$venueId');

  Future<EncryptedOfflineEnvelope> encryptJson(
    Map<String, Object?> value, {
    required String associatedData,
  }) async {
    await initialize();
    final secretBox = await _cipher.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: SecretKey(_masterKey!.sublist(0, 32)),
      aad: utf8.encode(associatedData),
    );
    return EncryptedOfflineEnvelope(
      nonce: Uint8List.fromList(secretBox.nonce),
      cipherText: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  Future<Map<String, Object?>> decryptJson(
    EncryptedOfflineEnvelope envelope, {
    required String associatedData,
  }) async {
    await initialize();
    final clearBytes = await _cipher.decrypt(
      SecretBox(
        envelope.cipherText,
        nonce: envelope.nonce,
        mac: Mac(envelope.mac),
      ),
      secretKey: SecretKey(_masterKey!.sublist(0, 32)),
      aad: utf8.encode(associatedData),
    );
    final decoded = jsonDecode(utf8.decode(clearBytes));
    if (decoded is! Map) {
      throw StateError('The offline event body is invalid.');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<String> eventHash(String canonicalEvent) =>
      _macString('event\u0000$canonicalEvent');

  Future<String> _macString(String value) async {
    await initialize();
    final mac = await _hmac.calculateMac(
      utf8.encode(value),
      secretKey: SecretKey(_masterKey!.sublist(32, 64)),
    );
    return base64UrlEncode(mac.bytes);
  }
}
