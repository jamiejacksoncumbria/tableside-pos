import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool venueHubHostingSupported({
  required bool isWeb,
  required TargetPlatform platform,
}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.windows);

bool get canHostVenueHub =>
    venueHubHostingSupported(isWeb: kIsWeb, platform: defaultTargetPlatform);

bool get canJoinVenueHubAsNativeClient =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Keeps an Android hub process and its Wi-Fi radio alive while the Dart hub
/// owns venue authority. Windows does not need this mobile lifecycle service.
class AndroidVenueHubService {
  AndroidVenueHubService._();

  static const _channel = MethodChannel('tableside/android_hub_service');

  static Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stop');
  }

  static Future<bool> isRunning() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  static Future<void> openBatterySettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('openBatterySettings');
  }
}
