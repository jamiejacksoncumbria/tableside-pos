import 'dart:io';

/// Performs a bounded TCP preflight to a Firebase dependency before starting
/// the Windows native Firebase SDK. A venue firewall can otherwise leave the
/// native initialisation call pending indefinitely and prevent the verified
/// LAN workspace from opening.
Future<bool> canReachFirebaseNetwork({
  Duration timeout = const Duration(seconds: 2),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      'firestore.googleapis.com',
      443,
      timeout: timeout,
    ).timeout(timeout);
    return true;
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}
