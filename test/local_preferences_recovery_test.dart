import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/local_preferences_recovery_native.dart';

void main() {
  test('retains every complete preference before a truncated number', () {
    const raw =
        '{"tableside.printDeviceId":"device-safe",'
        '"tableside.cachedVenueThemeMode":"dark",'
        '"unfinished":12e';

    expect(recoverCompletePreferences(raw), {
      'tableside.printDeviceId': 'device-safe',
      'tableside.cachedVenueThemeMode': 'dark',
    });
  });

  test('returns the complete object unchanged when passed valid JSON', () {
    final raw = jsonEncode({
      'name': 'TableSideCY',
      'enabled': true,
      'values': [1, 2, 3],
    });

    expect(recoverCompletePreferences(raw), {
      'name': 'TableSideCY',
      'enabled': true,
      'values': [1, 2, 3],
    });
  });

  test('fails safely when no top-level object can be recovered', () {
    expect(recoverCompletePreferences('not-json'), isEmpty);
    expect(recoverCompletePreferences('{"broken":"value'), isEmpty);
  });
}
