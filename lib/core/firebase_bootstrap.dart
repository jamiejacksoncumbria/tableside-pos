import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import '../firebase_options.dart';

bool _appCheckActivated = false;

Future<void> initializeFirebase() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  await _activateAppCheck();
}

/// Activates only providers that are safe for the current TableSide rollout.
/// Android uses Play Integrity and iOS uses App Attest with a DeviceCheck
/// fallback in release builds. Windows currently has only Firebase's debug
/// provider, so it is opt-in until a production desktop provider is available.
Future<void> _activateAppCheck() async {
  if (_appCheckActivated) return;
  try {
    if (kIsWeb) {
      const webSiteKey = String.fromEnvironment(
        'TABLESIDE_WEB_APP_CHECK_RECAPTCHA_SITE_KEY',
      );
      final useDebugProvider = kDebugMode;
      if (!useDebugProvider && webSiteKey.isEmpty) {
        AppLogger.info(
          'Firebase App Check is not active on web: supply TABLESIDE_WEB_APP_CHECK_RECAPTCHA_SITE_KEY for a production web build.',
        );
        return;
      }
      await FirebaseAppCheck.instance.activate(
        providerWeb: useDebugProvider
            ? WebDebugProvider()
            : ReCaptchaV3Provider(webSiteKey),
      );
      _appCheckActivated = true;
      AppLogger.info(
        'Firebase App Check activated for web (${useDebugProvider ? 'debug' : 'reCAPTCHA v3'} provider).',
      );
      return;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final useDebugProvider = kDebugMode || kProfileMode;
        await FirebaseAppCheck.instance.activate(
          providerAndroid: useDebugProvider
              ? const AndroidDebugProvider()
              : const AndroidPlayIntegrityProvider(),
        );
        _appCheckActivated = true;
        AppLogger.info(
          'Firebase App Check activated for Android (${useDebugProvider ? 'debug' : 'Play Integrity'} provider).',
        );
      case TargetPlatform.iOS:
        final useDebugProvider = kDebugMode || kProfileMode;
        await FirebaseAppCheck.instance.activate(
          providerApple: useDebugProvider
              ? const AppleDebugProvider()
              : const AppleAppAttestWithDeviceCheckFallbackProvider(),
        );
        _appCheckActivated = true;
        AppLogger.info(
          'Firebase App Check activated for iOS (${useDebugProvider ? 'debug' : 'App Attest'} provider).',
        );
      case TargetPlatform.windows:
        const windowsDebugToken = String.fromEnvironment(
          'TABLESIDE_WINDOWS_APP_CHECK_DEBUG_TOKEN',
        );
        if (windowsDebugToken.isEmpty) {
          AppLogger.info(
            'Firebase App Check is not active on Windows: configure a registered debug token before enforcing desktop requests.',
          );
          return;
        }
        await FirebaseAppCheck.instance.activate(
          providerWindows: const WindowsDebugProvider(
            debugToken: windowsDebugToken,
          ),
        );
        _appCheckActivated = true;
        AppLogger.info('Firebase App Check activated for Windows debug.');
      default:
        AppLogger.info(
          'Firebase App Check is not configured for this platform yet.',
        );
    }
  } on Object catch (error, stackTrace) {
    // During the monitor phase we keep normal POS access available, but never
    // hide a failed attestation setup from the debug console.
    AppLogger.error('Firebase App Check activation', error, stackTrace);
  }
}

/// Returns a token for TableSide's own HTTP APIs. Firestore and Storage attach
/// their token automatically after activation. A missing token is accepted
/// only while the server is in the monitor phase.
Future<String?> currentFirebaseAppCheckToken() async {
  if (!_appCheckActivated) return null;
  try {
    final token = await FirebaseAppCheck.instance.getToken();
    if (token == null || token.isEmpty) {
      AppLogger.info('Firebase App Check has no current token.');
      return null;
    }
    return token;
  } on Object catch (error, stackTrace) {
    AppLogger.error('Firebase App Check token', error, stackTrace);
    return null;
  }
}
