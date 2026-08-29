import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

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

  Future<String?> credential() =>
      _preferences.getString(_credentialPreferenceKey);

  Future<void> saveCredential(String credential) =>
      _preferences.setString(_credentialPreferenceKey, credential);

  Future<void> clearCredential() =>
      _preferences.remove(_credentialPreferenceKey);
}
