import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import 'venue_hub_bootstrap.dart';

/// Non-secret discovery cache needed after a till restarts without internet.
/// PIN hashes, signing seeds and session tokens are never stored here.
class VenueHubClientCache {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  String _key(VenueScope scope, String kind) =>
      'tableside.hubCache.${scope.tenantId}.${scope.venueId}.$kind';

  Future<void> saveBootstrap(VenueScope scope, VenueHubBootstrap value) =>
      _preferences.setString(
        _key(scope, 'bootstrap'),
        jsonEncode(value.toJson()),
      );

  Future<VenueHubBootstrap?> readBootstrap(VenueScope scope) async {
    final raw = await _preferences.getString(_key(scope, 'bootstrap'));
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map
          ? VenueHubBootstrap.fromJson(Map<String, Object?>.from(value))
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveStaff(VenueScope scope, List<VenuePinStaff> staff) =>
      _preferences.setString(
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
                },
              )
              .toList(growable: false),
        ),
      );

  Future<List<VenuePinStaff>> readStaff(VenueScope scope) async {
    final raw = await _preferences.getString(_key(scope, 'staff'));
    if (raw == null) return const [];
    try {
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
            );
          })
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
