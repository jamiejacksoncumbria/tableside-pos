import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'firebase_environment_options.dart';

/// Runs in a separate isolate when iOS or Android delivers a background data
/// message. Keep this entry point free of UI and staff-session state.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: FirebaseEnvironmentOptions.currentPlatform,
    );
  }
  if (kDebugMode) {
    debugPrint(
      'TABLESIDE DEBUG Background push received: '
      '${message.data['type'] ?? 'operational'}.',
    );
  }
}

/// Must be registered before [runApp] so terminated/background delivery has a
/// stable top-level callback entry point in release and TestFlight builds.
void registerFirebaseMessagingBackgroundHandler() {
  if (kIsWeb) return;
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
}
