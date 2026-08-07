import 'package:firebase_core/firebase_core.dart';

/// Runtime configuration avoids committing a restaurant's Firebase project IDs
/// to the application source. Supply the values with `--dart-define` in local
/// launch configurations and CI/CD secrets.
abstract final class FirebaseRuntimeConfig {
  static const enabled = bool.fromEnvironment('TABLESIDE_USE_FIREBASE');
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );

  static bool get isConfigured =>
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _projectId.isNotEmpty;

  static FirebaseOptions get options {
    if (!isConfigured) {
      throw StateError(
        'Firebase is enabled but configuration is missing. See README.md for the required dart-defines.',
      );
    }
    return const FirebaseOptions(
      apiKey: _apiKey,
      appId: _appId,
      messagingSenderId: _senderId,
      projectId: _projectId,
      authDomain: _authDomain,
      storageBucket: _storageBucket,
    );
  }
}
