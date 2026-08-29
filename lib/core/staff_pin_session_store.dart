class StaffPinSessionCredentials {
  const StaffPinSessionCredentials({
    required this.sessionId,
    required this.sessionToken,
  });

  final String sessionId;
  final String sessionToken;
}

/// Process-memory credentials for the currently selected person on a shared
/// device. They are deliberately never persisted to disk.
class StaffPinSessionStore {
  StaffPinSessionStore._();

  static StaffPinSessionCredentials? current;
}
