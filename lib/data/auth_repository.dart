import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(FirebaseAuth.instance),
);

final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges(),
);

class AuthRepository {
  AuthRepository(this._auth);

  final FirebaseAuth _auth;

  // Custom claims (such as `platformAdmin`) arrive in a refreshed ID token.
  // Watching token changes ensures the UI reevaluates access immediately after
  // a claim is granted, rather than waiting for a later sign-in.
  Stream<User?> authStateChanges() => _auth.idTokenChanges().map((user) {
    // Do not log an email or UID. This marker distinguishes a Firebase stream
    // problem from a native renderer that has received but not painted UI.
    AppLogger.info(
      'Firebase authentication gate resolved: '
      '${user == null ? 'signed out' : 'signed in'}.',
    );
    return user;
  });

  Future<void> signIn({required String email, required String password}) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> sendPasswordReset(String email) {
    return _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> signOut() => _auth.signOut();
}
