import 'offline_event.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_protocol.dart';

class VenueHubStaffGrant {
  const VenueHubStaffGrant({
    required this.staffId,
    required this.permissions,
    required this.expiresAtUtc,
    required this.pinVersion,
    required this.membershipVersion,
    this.active = true,
  });

  final String staffId;
  final Set<String> permissions;
  final DateTime expiresAtUtc;
  final int pinVersion;
  final int membershipVersion;
  final bool active;
}

typedef VenueHubStaffAuthorizer =
    Future<VenueHubStaffGrant?> Function(String staffId);
typedef VenueHubEventCommitter =
    Future<OfflineEvent> Function(OfflineEventDraft draft, int hubEpoch);

class VenueHubCommandAcknowledgement {
  const VenueHubCommandAcknowledgement({
    required this.eventId,
    required this.sequence,
    required this.eventHash,
    required this.committedAtUtc,
  });

  final String eventId;
  final int sequence;
  final String eventHash;
  final DateTime committedAtUtc;
}

/// Security and durability boundary used by the local HTTPS handler. A valid
/// device signature alone is insufficient: the cached staff grant must also be
/// active, current and explicitly permit the requested operation.
class VenueHubCommandProcessor {
  VenueHubCommandProcessor({
    required this.tenantId,
    required this.venueId,
    required this.hubEpoch,
    required Map<String, VenueHubPublicCredential> credentials,
    required VenueHubStaffAuthorizer authorizeStaff,
    required VenueHubEventCommitter commitEvent,
    VenueHubReplayGuard? replayGuard,
  }) : credentials = Map.unmodifiable(credentials),
       _authorizeStaff = authorizeStaff,
       _commitEvent = commitEvent,
       _replayGuard = replayGuard ?? VenueHubReplayGuard() {
    if (hubEpoch < 1) {
      throw ArgumentError.value(hubEpoch, 'hubEpoch', 'Must be positive.');
    }
  }

  final String tenantId;
  final String venueId;
  final int hubEpoch;
  final Map<String, VenueHubPublicCredential> credentials;
  final VenueHubStaffAuthorizer _authorizeStaff;
  final VenueHubEventCommitter _commitEvent;
  final VenueHubReplayGuard _replayGuard;

  static const _permissionByEvent = <String, String>{
    'order.opened': 'order',
    'order.itemAdded': 'order',
    'order.itemQuantityChanged': 'order',
    'order.sent': 'order',
    'payment.recorded': 'payment',
    'order.closed': 'payment',
  };

  Future<VenueHubCommandAcknowledgement> process({
    required VenueHubRequestEnvelope envelope,
    required Map<String, Object?> body,
    required DateTime trustedNowUtc,
  }) async {
    if (envelope.method != 'POST' || envelope.path != '/v1/events') {
      throw const VenueHubCommandException(
        'The hub endpoint is not supported.',
      );
    }
    final eventType = body['eventType'];
    final permission = eventType is String
        ? _permissionByEvent[eventType]
        : null;
    if (permission == null) {
      throw const VenueHubCommandException(
        'The staff member cannot perform this offline operation.',
      );
    }
    await authenticate(
      envelope: envelope,
      body: body,
      trustedNowUtc: trustedNowUtc,
      requiredPermission: permission,
    );
    final rawPayload = body['payload'];
    if (rawPayload is! Map) {
      throw const VenueHubCommandException(
        'The offline event payload is invalid.',
      );
    }
    DateTime? businessTimestamp;
    final rawTimestamp = body['businessTimestampUtc'];
    if (rawTimestamp != null) {
      if (rawTimestamp is! String) {
        throw const VenueHubCommandException(
          'The business timestamp is invalid.',
        );
      }
      businessTimestamp = DateTime.tryParse(rawTimestamp)?.toUtc();
      if (businessTimestamp == null) {
        throw const VenueHubCommandException(
          'The business timestamp is invalid.',
        );
      }
    }
    final committed = await _commitEvent(
      OfflineEventDraft(
        tenantId: tenantId,
        venueId: venueId,
        deviceId: envelope.deviceId,
        staffId: envelope.staffId,
        type: eventType as String,
        payload: Map<String, Object?>.from(rawPayload),
        businessTimestamp: businessTimestamp,
      ),
      hubEpoch,
    );
    return VenueHubCommandAcknowledgement(
      eventId: committed.id,
      sequence: committed.sequence,
      eventHash: committed.eventHash,
      committedAtUtc: committed.createdAtUtc,
    );
  }

  Future<VenueHubStaffGrant> authenticate({
    required VenueHubRequestEnvelope envelope,
    required Map<String, Object?> body,
    required DateTime trustedNowUtc,
    required String requiredPermission,
  }) async {
    final credential = credentials[envelope.credentialId];
    if (credential == null || credential.deviceId != envelope.deviceId) {
      throw const VenueHubCommandException(
        'This device credential is not active at the venue.',
      );
    }
    await _replayGuard.verify(
      envelope: envelope,
      body: body,
      credentialPublicKey: credential.publicKey,
      expectedTenantId: tenantId,
      expectedVenueId: venueId,
      expectedHubEpoch: hubEpoch,
      trustedNowUtc: trustedNowUtc,
    );
    final grant = await _authorizeStaff(envelope.staffId);
    if (grant == null ||
        !grant.active ||
        grant.staffId != envelope.staffId ||
        !grant.expiresAtUtc.toUtc().isAfter(trustedNowUtc.toUtc()) ||
        grant.pinVersion < 1 ||
        grant.membershipVersion < 1) {
      throw const VenueHubCommandException(
        'The staff session is unavailable, expired, or revoked.',
      );
    }
    if (!grant.permissions.contains(requiredPermission)) {
      throw const VenueHubCommandException(
        'The staff member cannot perform this offline operation.',
      );
    }
    return grant;
  }
}

class VenueHubCommandException implements Exception {
  const VenueHubCommandException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubCommandException: $message';
}
