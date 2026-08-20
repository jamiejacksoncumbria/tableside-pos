import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Stream<User?> authStateChanges() => _auth.idTokenChanges();

  Future<void> signIn({required String email, required String password}) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> sendPasswordReset(String email) {
    return _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> signOut() => _auth.signOut();
}
