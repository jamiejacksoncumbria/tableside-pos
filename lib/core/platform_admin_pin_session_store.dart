class PlatformAdminPinSession {
  const PlatformAdminPinSession({
    required this.sessionId,
    required this.sessionToken,
    required this.expiresAt,
  });

  final String sessionId;
  final String sessionToken;
  final DateTime expiresAt;

  bool get isValid => expiresAt.isAfter(DateTime.now());
}

/// Platform credentials stay only in process memory. Closing, signing out, or
/// restarting the app always requires the administrator PIN again.
class PlatformAdminPinSessionStore {
  PlatformAdminPinSessionStore._();

  static PlatformAdminPinSession? current;

  static void clear() => current = null;
}
