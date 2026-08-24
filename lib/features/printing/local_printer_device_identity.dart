import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A locally persisted, random physical-device identity. It is not an
/// authentication credential; Firestore additionally checks the account the
/// manager assigned to this device.
class LocalPrinterDeviceIdentity {
  static const _preferenceKey = 'tableside.printDeviceId';

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
}
