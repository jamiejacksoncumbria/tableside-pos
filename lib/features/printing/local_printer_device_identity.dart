import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/tenant_scope.dart';

/// A locally persisted, random physical-device identity. It is not an
/// authentication credential. The separately persisted enrollment credential
/// is issued by the server after a manager authorises this physical device.
class LocalPrinterDeviceIdentity {
  static const _preferenceKey = 'tableside.printDeviceId';
  static const _credentialPreferenceKey = 'tableside.printDeviceCredential';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<String> getOrCreate() async {
    final existing = await _preferences.getString(_preferenceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final segments = List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    );
    final id = 'device-${segments.join()}';
    await _preferences.setString(_preferenceKey, id);
    return id;
  }

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

  /// Compatibility for a device configured before venue-scoped enrolment.
  /// New registrations never write this key. The worker can use it only until
  /// the manager registers this physical device for the relevant venue.
  Future<String?> legacyCredential() async {
    final secured = await _secureStorage.read(key: _credentialPreferenceKey);
    if (secured?.isNotEmpty == true) return secured;
    final legacy = await _preferences.getString(_credentialPreferenceKey);
    if (legacy?.isNotEmpty == true) {
      await _secureStorage.write(key: _credentialPreferenceKey, value: legacy);
      await _preferences.remove(_credentialPreferenceKey);
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
    await _preferences.remove(_preferenceKey);
    await _preferences.remove(_credentialPreferenceKey);
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
