import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/tenant_scope.dart';

/// A locally persisted, random physical-device identity. It is not an
/// authentication credential. The separately persisted enrollment credential
/// is issued by the server after a manager authorises this physical device.
class LocalPrinterDeviceIdentity {
  // Version 1 was stored in ordinary SharedPreferences. Android backup and
  // emulator/device cloning could copy that value to another installation,
  // causing two physical devices to present the same identifier. Never
  // migrate that value: v2 deliberately rotates every installation onto a
  // random identity held in the OS credential store.
  static const _legacyPreferenceKey = 'tableside.printDeviceId';
  static const _secureIdentityKey = 'tableside.deviceIdentity.v2';
  static const _credentialPreferenceKey = 'tableside.printDeviceCredential';

  static Future<String>? _identityLoad;

  SharedPreferencesAsync get _preferences => SharedPreferencesAsync();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    // `this_device` prevents an encrypted iCloud/iTunes restore from copying
    // an enrolled till identity onto a different Apple device.
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Future<String> getOrCreate() async {
    // Several startup hosts request the identity concurrently. A process-wide
    // single flight prevents them from generating different IDs during the
    // first launch while secure storage is still empty.
    final existingLoad = _identityLoad;
    if (existingLoad != null) return existingLoad;
    final load = _loadOrCreate();
    _identityLoad = load;
    try {
      return await load;
    } catch (_) {
      if (identical(_identityLoad, load)) _identityLoad = null;
      rethrow;
    }
  }

  Future<String> _loadOrCreate() async {
    final existing = await _secureStorage.read(key: _secureIdentityKey);
    if (existing != null && _isValidV2Identity(existing)) return existing;
    final random = Random.secure();
    final segments = List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    );
    final id = 'device-v2-${segments.join()}';
    await _secureStorage.write(key: _secureIdentityKey, value: id);
    // Delete the clonable v1 value only after the protected v2 write succeeds.
    try {
      await _preferences.remove(_legacyPreferenceKey);
    } catch (_) {
      // The legacy value is no longer read and therefore cannot grant access.
      // Preference plugins may be unavailable in isolated unit tests or while
      // a platform is still starting, so deletion is intentionally best effort.
    }
    return id;
  }

  bool _isValidV2Identity(String value) =>
      RegExp(r'^device-v2-[0-9a-f]{32}$').hasMatch(value);

  /// One physical device can serve more than one venue. Each venue receives a
  /// different registration and server-issued credential, so changing venue
  /// never steals the printer from the venue that was configured first.
  Future<String> deviceIdForScope(VenueScope scope) async {
    final physicalId = await getOrCreate();
    return '$physicalId-${_scopeHash(scope)}';
  }

  Future<String?> credential(VenueScope scope) async {
    final key = _credentialKey(scope);
    final secured = await _secureStorage.read(key: key);
    if (secured?.isNotEmpty == true) return secured;
    // One-time migration from releases which incorrectly kept this bearer
    // credential in ordinary preferences. Remove the clear-text copy only
    // after the protected write succeeds.
    final legacy = await _preferences.getString(key);
    if (legacy?.isNotEmpty == true) {
      await _secureStorage.write(key: key, value: legacy);
      await _preferences.remove(key);
      return legacy;
    }
    return null;
  }

  Future<void> saveCredential(VenueScope scope, String credential) async {
    final key = _credentialKey(scope);
    await _secureStorage.write(key: key, value: credential);
    await _preferences.remove(key);
  }

  Future<void> clearCredential(VenueScope scope) async {
    final key = _credentialKey(scope);
    await _secureStorage.delete(key: key);
    await _preferences.remove(key);
  }

  Future<void> reset() async {
    _identityLoad = null;
    await _preferences.remove(_legacyPreferenceKey);
    await _preferences.remove(_credentialPreferenceKey);
    await _secureStorage.delete(key: _secureIdentityKey);
    final secured = await _secureStorage.readAll();
    for (final key in secured.keys.where(
      (key) =>
          key == _credentialPreferenceKey ||
          key.startsWith('$_credentialPreferenceKey.'),
    )) {
      await _secureStorage.delete(key: key);
    }
  }

  String _credentialKey(VenueScope scope) =>
      '$_credentialPreferenceKey.${_scopeHash(scope)}';

  // A stable FNV-1a hash keeps document IDs short without putting tenant or
  // venue IDs into local preference keys or Firestore document IDs.
  String _scopeHash(VenueScope scope) {
    var hash = 0x811c9dc5;
    for (final unit in '${scope.tenantId}/${scope.venueId}'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
