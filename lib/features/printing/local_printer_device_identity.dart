import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/tenant_scope.dart';

/// A locally persisted, random physical-device identity. It is not an
/// authentication credential. The separately persisted enrollment credential
/// is issued by the server after a manager authorises this physical device.
class LocalPrinterDeviceIdentity {
  static const _preferenceKey = 'tableside.printDeviceId';
  static const _credentialPreferenceKey = 'tableside.printDeviceCredential';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

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

  Future<String?> credential(VenueScope scope) =>
      _preferences.getString(_credentialKey(scope));

  /// Compatibility for a device configured before venue-scoped enrolment.
  /// New registrations never write this key. The worker can use it only until
  /// the manager registers this physical device for the relevant venue.
  Future<String?> legacyCredential() =>
      _preferences.getString(_credentialPreferenceKey);

  Future<void> saveCredential(VenueScope scope, String credential) =>
      _preferences.setString(_credentialKey(scope), credential);

  Future<void> clearCredential(VenueScope scope) =>
      _preferences.remove(_credentialKey(scope));

  Future<void> reset() async {
    await _preferences.remove(_preferenceKey);
    await _preferences.remove(_credentialPreferenceKey);
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
