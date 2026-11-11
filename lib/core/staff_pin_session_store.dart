class StaffPinSessionCredentials {
  const StaffPinSessionCredentials({
    required this.sessionId,
    required this.sessionToken,
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
  });

  final String sessionId;
  final String sessionToken;
  final String tenantId;
  final String venueId;
  final String deviceId;
}

/// Process-memory credentials for the currently selected person on a shared
/// device. They are deliberately never persisted to disk.
class StaffPinSessionStore {
  StaffPinSessionStore._();

  static StaffPinSessionCredentials? current;
}
