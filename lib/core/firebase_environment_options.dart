import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'app_environment.dart';

/// Selects exactly one Firebase environment at compile time.
///
/// Staging deliberately uses the existing `table-pos` FlutterFire file.
/// Production has no fallback: every public Firebase identifier must be
/// supplied with `--dart-define-from-file`, and it must name a different
/// project. This prevents a production-looking build from writing test data.
abstract final class FirebaseEnvironmentOptions {
  static FirebaseOptions get currentPlatform {
    final options = AppEnvironment.isStaging
        ? DefaultFirebaseOptions.currentPlatform
        : _productionPlatform;
    _validate(options);
    return options;
  }

  static FirebaseOptions get _productionPlatform {
    if (kIsWeb) return _productionWeb;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _productionAndroid;
      case TargetPlatform.iOS:
        return _productionIos;
      case TargetPlatform.windows:
        return _productionWindows;
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'Production Firebase is not configured for this platform.',
        );
    }
  }

  static void _validate(FirebaseOptions options) {
    if (AppEnvironment.isStaging) {
      if (options.projectId != 'table-pos') {
        throw StateError(
          'The staging build must use the table-pos Firebase project.',
        );
      }
      return;
    }
    if (options.projectId.isEmpty ||
        options.projectId == 'table-pos' ||
        options.apiKey.isEmpty ||
        options.appId.isEmpty ||
        options.messagingSenderId.isEmpty) {
      throw StateError(
        'Production Firebase is not configured, or it points at staging. '
        'Create config/firebase-production.json from the supplied example.',
      );
    }
  }

  static const _projectId = String.fromEnvironment(
    'TABLESIDE_PRODUCTION_FIREBASE_PROJECT_ID',
  );
  static const _senderId = String.fromEnvironment(
    'TABLESIDE_PRODUCTION_FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _storageBucket = String.fromEnvironment(
    'TABLESIDE_PRODUCTION_FIREBASE_STORAGE_BUCKET',
  );
  static const _authDomain = String.fromEnvironment(
    'TABLESIDE_PRODUCTION_FIREBASE_AUTH_DOMAIN',
  );

  static const _productionWeb = FirebaseOptions(
    apiKey: String.fromEnvironment('TABLESIDE_PRODUCTION_FIREBASE_WEB_API_KEY'),
    appId: String.fromEnvironment('TABLESIDE_PRODUCTION_FIREBASE_WEB_APP_ID'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _storageBucket,
  );

  static const _productionWindows = FirebaseOptions(
    apiKey: String.fromEnvironment(
      'TABLESIDE_PRODUCTION_FIREBASE_WINDOWS_API_KEY',
    ),
    appId: String.fromEnvironment(
      'TABLESIDE_PRODUCTION_FIREBASE_WINDOWS_APP_ID',
    ),
    messagingSenderId: _senderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _storageBucket,
  );

  static const _productionAndroid = FirebaseOptions(
    apiKey: String.fromEnvironment(
      'TABLESIDE_PRODUCTION_FIREBASE_ANDROID_API_KEY',
    ),
    appId: String.fromEnvironment(
      'TABLESIDE_PRODUCTION_FIREBASE_ANDROID_APP_ID',
    ),
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
  );

  static const _productionIos = FirebaseOptions(
    apiKey: String.fromEnvironment('TABLESIDE_PRODUCTION_FIREBASE_IOS_API_KEY'),
    appId: String.fromEnvironment('TABLESIDE_PRODUCTION_FIREBASE_IOS_APP_ID'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
    iosBundleId: String.fromEnvironment(
      'TABLESIDE_PRODUCTION_FIREBASE_IOS_BUNDLE_ID',
      defaultValue: 'uk.co.gopcpitstop.tablesideCY',
    ),
  );
}
