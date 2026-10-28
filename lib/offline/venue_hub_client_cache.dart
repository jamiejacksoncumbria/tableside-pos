import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';
import '../data/production_command_repository.dart';
import 'venue_hub_bootstrap.dart';

/// Non-secret discovery cache needed after a till restarts without internet.
/// PIN hashes, signing seeds and session tokens are never stored here.
class VenueHubClientCache {
  VenueHubClientCache({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final FlutterSecureStorage _secureStorage;

  static const _lastScopeKey = 'tableside.hubCache.lastScope';
  static const _durableBootstrapPrefix =
      'tableside.hubCache.durableBootstrap.v1.';

  String _key(VenueScope scope, String kind) =>
      'tableside.hubCache.${scope.tenantId}.${scope.venueId}.$kind';

  String _durableBootstrapKey(VenueScope scope) =>
      '$_durableBootstrapPrefix'
      '${base64UrlEncode(utf8.encode(scope.tenantId)).replaceAll('=', '')}.'
      '${base64UrlEncode(utf8.encode(scope.venueId)).replaceAll('=', '')}';

  VenueScope? _scopeFromDurableBootstrapKey(String key) {
    if (!key.startsWith(_durableBootstrapPrefix)) return null;
    final encoded = key.substring(_durableBootstrapPrefix.length).split('.');
    if (encoded.length != 2) return null;
    try {
      final tenantId = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded[0])),
      );
      final venueId = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded[1])),
      );
      if (tenantId.isEmpty || venueId.isEmpty) return null;
      return VenueScope(tenantId: tenantId, venueId: venueId);
    } on Object {
      return null;
    }
  }

  Future<void> saveBootstrap(VenueScope scope, VenueHubBootstrap value) async {
    final encoded = jsonEncode(value.toJson());
    try {
      await _preferences.setString(_key(scope, 'bootstrap'), encoded);
      // This is discovery data, not authority. Cold-start recovery validates
      // the installation-bound device ID, Ed25519 credential, hub epoch and
      // encrypted snapshot again before it opens the offline workspace.
      await _preferences.setString(
        _lastScopeKey,
        jsonEncode(<String, String>{
          'tenantId': scope.tenantId,
          'venueId': scope.venueId,
        }),
      );
    } on Object {
      // Discovery caching is best-effort. A local storage fault must never
      // turn a successful cloud response into a failed venue load.
    }
    try {
      // Windows SharedPreferences is one JSON file. A power cut can truncate
      // it and erase the scope index during repair, even while the encrypted
      // SQLite venue snapshot and installation-bound credentials remain
      // intact. Keep a redundant OS-protected copy of the cloud bootstrap so
      // an enrolled hub can rediscover and fully revalidate that durable data.
      await _secureStorage.write(
        key: _durableBootstrapKey(scope),
        value: encoded,
      );
    } on Object {
      // Secure backup failure does not invalidate the live cloud response or
      // the ordinary preferences cache. Offline startup still fails closed.
    }
  }

  /// Returns possible cached scopes in most-recent-first order.
  ///
  /// Older installations pre-date [lastScope], so bootstrap preference keys
  /// are also inspected. A scope discovered here is never trusted on its own;
  /// the offline startup verifier must still match this physical device and
  /// its private signing credential to the cloud-signed cached bootstrap.
  Future<List<VenueScope>> readCandidateScopes() async {
    final result = <VenueScope>[];
    final seen = <String>{};

    void add(VenueScope scope) {
      final key = '${scope.tenantId}\u0000${scope.venueId}';
      if (seen.add(key)) result.add(scope);
    }

    try {
      final raw = await _preferences.getString(_lastScopeKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        final tenantId = decoded['tenantId'];
        final venueId = decoded['venueId'];
        if (tenantId is String &&
            tenantId.isNotEmpty &&
            venueId is String &&
            venueId.isNotEmpty) {
          add(VenueScope(tenantId: tenantId, venueId: venueId));
        }
      }
    } catch (_) {
      // Fall through to legacy key discovery.
    }

    try {
      const prefix = 'tableside.hubCache.';
      const suffix = '.bootstrap';
      final keys = await _preferences.getKeys();
      for (final key in keys) {
        if (!key.startsWith(prefix) || !key.endsWith(suffix)) continue;
        final middle = key.substring(prefix.length, key.length - suffix.length);
        final separator = middle.indexOf('.');
        if (separator <= 0 || separator == middle.length - 1) continue;
        add(
          VenueScope(
            tenantId: middle.substring(0, separator),
            venueId: middle.substring(separator + 1),
          ),
        );
      }
    } catch (_) {
      // Missing/corrupt preferences correctly produce no offline workspace.
    }
    try {
      final secured = await _secureStorage.readAll();
      for (final key in secured.keys) {
        final scope = _scopeFromDurableBootstrapKey(key);
        if (scope != null) add(scope);
      }
    } catch (_) {
      // The encrypted SQLite snapshot cannot be safely located without a
      // scope. If both discovery stores are unavailable, fail closed.
    }
    return result;
  }

  Future<VenueHubBootstrap?> readBootstrap(VenueScope scope) async {
    VenueHubBootstrap? decode(String? raw) {
      if (raw == null) return null;
      final value = jsonDecode(raw);
      return value is Map
          ? VenueHubBootstrap.fromJson(Map<String, Object?>.from(value))
          : null;
    }

    try {
      final raw = await _preferences.getString(_key(scope, 'bootstrap'));
      final cached = decode(raw);
      if (cached != null) return cached;
    } catch (_) {
      // Fall through to the redundant OS-protected bootstrap.
    }
    try {
      return decode(
        await _secureStorage.read(key: _durableBootstrapKey(scope)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Saves non-secret venue presentation data required to render the locked
  /// PIN screen during an internet outage. Operational authority continues to
  /// come from the device key, pinned TLS hub and staff PIN.
  Future<void> saveWorkspace(
    VenueScope scope,
    TenantProfile profile,
    Venue venue,
  ) async {
    try {
      await _preferences.setString(
        _key(scope, 'workspace'),
        jsonEncode(<String, Object?>{
          'tenantName': profile.displayName,
          'tenantLegalName': profile.legalName,
          'currencyCode': profile.currencyCode,
          'logoUrl': profile.logoUrl,
          'tenantAddress': profile.address,
          'tenantPhoneNumbers': profile.phoneNumbers,
          'venueName': venue.name,
          'venueTimeZone': venue.timeZone,
          'venueCountry': venue.country,
          'deliveryLocations': venue.deliveryLocations,
          'venueAddress': venue.address,
          'venuePhoneNumbers': venue.phoneNumbers,
          'receiptFooter': venue.receiptFooter,
          'collectionEnabled': venue.collectionEnabled,
          'deliveryEnabled': venue.deliveryEnabled,
          'courseControlEnabled': venue.courseControlEnabled,
          'notificationRetentionSeconds': venue.notificationRetentionSeconds,
          'backgroundLockSeconds': venue.backgroundLockSeconds,
          'orderFlowAmberMinutes': venue.orderFlowAmberMinutes,
          'orderFlowRedMinutes': venue.orderFlowRedMinutes,
          'defaultBookingDurationMinutes': venue.defaultBookingDurationMinutes,
          'businessDayCutoffMinutes': venue.businessDayCutoffMinutes,
          'defaultThemeMode': venue.defaultThemeMode,
        }),
      );
    } on Object {
      // The live cloud workspace remains authoritative and usable.
    }
  }

  Future<Map<String, Object?>?> readWorkspace(VenueScope scope) async {
    try {
      final raw = await _preferences.getString(_key(scope, 'workspace'));
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveStaff(VenueScope scope, List<VenuePinStaff> staff) async {
    try {
      await _preferences.setString(
        _key(scope, 'staff'),
        jsonEncode(
          staff
              .map(
                (item) => <String, Object?>{
                  'userId': item.userId,
                  'displayName': item.displayName,
                  'roles': item.roles,
                  'hasPin': item.hasPin,
                  'pinLocked': item.pinLocked,
                  'offlineReady': item.offlineReady,
                },
              )
              .toList(growable: false),
        ),
      );
    } on Object {
      // The online staff list remains authoritative and usable even if this
      // optional offline-discovery cache cannot be written.
    }
  }

  Future<List<VenuePinStaff>> readStaff(VenueScope scope) async {
    try {
      final raw = await _preferences.getString(_key(scope, 'staff'));
      if (raw == null) return const [];
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((item) {
            final value = Map<String, Object?>.from(item);
            return VenuePinStaff(
              userId: value['userId'] as String,
              displayName: value['displayName'] as String,
              roles: (value['roles'] as List).whereType<String>().toList(),
              hasPin: value['hasPin'] == true,
              pinLocked: value['pinLocked'] == true,
              offlineReady: value['offlineReady'] == true,
            );
          })
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  String _staffPreferenceKey(VenueScope scope, String userId) =>
      _key(scope, 'staffPreference.${Uri.encodeComponent(userId)}');

  /// Saves presentation-only staff choices for a terminal that may restart
  /// without Firebase. This contains no PIN, permission or session authority.
  Future<void> saveStaffPreferences(
    VenueScope scope, {
    required String userId,
    required String themeModePreference,
    required String posCategoryViewPreference,
    required String posProductSortPreference,
  }) async {
    try {
      await _preferences.setString(
        _staffPreferenceKey(scope, userId),
        jsonEncode(<String, String>{
          'themeModePreference': themeModePreference,
          'posCategoryViewPreference': posCategoryViewPreference,
          'posProductSortPreference': posProductSortPreference,
        }),
      );
    } on Object {
      // Preferences never participate in authentication or POS authority.
    }
  }

  Future<Map<String, String>> readStaffPreferences(
    VenueScope scope,
    String userId,
  ) async {
    try {
      final raw = await _preferences.getString(
        _staffPreferenceKey(scope, userId),
      );
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } on Object {
      return const <String, String>{};
    }
  }
}
