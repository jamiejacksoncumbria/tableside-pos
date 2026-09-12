import 'dart:collection';

enum OfflineEventSyncState { pending, inFlight, synced, quarantined }

enum OfflineTimeAuthority { deviceUnverified, firebaseEstimate, venueHub }

/// An operation that must be committed locally before the UI reports success.
///
/// The payload must contain business inputs, never Firebase ID tokens, staff
/// PINs, card data, database keys, or other credentials.
class OfflineEventDraft {
  OfflineEventDraft({
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
    required this.staffId,
    required this.type,
    required Map<String, Object?> payload,
    this.managerApprovalStaffId,
    this.businessTimestamp,
  }) : payload = UnmodifiableMapView(Map<String, Object?>.from(payload)) {
    _requireIdentifier('tenantId', tenantId);
    _requireIdentifier('venueId', venueId);
    _requireIdentifier('deviceId', deviceId);
    _requireIdentifier('staffId', staffId);
    _requireIdentifier('type', type);
    if (managerApprovalStaffId != null) {
      _requireIdentifier('managerApprovalStaffId', managerApprovalStaffId!);
    }
  }

  final String tenantId;
  final String venueId;
  final String deviceId;
  final String staffId;
  final String? managerApprovalStaffId;
  final String type;
  final Map<String, Object?> payload;
  final DateTime? businessTimestamp;

  static void _requireIdentifier(String name, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 160) {
      throw ArgumentError.value(value, name, 'Must contain 1–160 characters.');
    }
  }
}

class OfflineEvent {
  const OfflineEvent({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
    required this.staffId,
    required this.type,
    required this.payload,
    required this.createdAtUtc,
    required this.deviceObservedAtUtc,
    required this.timeAuthority,
    required this.clockSkewMillis,
    required this.businessTimestampUtc,
    required this.sequence,
    required this.hubEpoch,
    required this.previousHash,
    required this.eventHash,
    required this.syncState,
    this.managerApprovalStaffId,
    this.cloudAcknowledgedAtUtc,
    this.quarantineReason,
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String deviceId;
  final String staffId;
  final String? managerApprovalStaffId;
  final String type;
  final Map<String, Object?> payload;
  final DateTime createdAtUtc;
  final DateTime deviceObservedAtUtc;
  final OfflineTimeAuthority timeAuthority;
  final int clockSkewMillis;
  final DateTime businessTimestampUtc;
  final int sequence;
  final int hubEpoch;
  final String previousHash;
  final String eventHash;
  final OfflineEventSyncState syncState;
  final DateTime? cloudAcknowledgedAtUtc;
  final String? quarantineReason;
}
