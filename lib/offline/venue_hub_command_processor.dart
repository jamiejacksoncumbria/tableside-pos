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
    Future<VenueHubStaffGrant?> Function(
      String staffId,
      String sessionId,
      String sessionToken,
    );
typedef VenueHubEventCommitter =
    Future<OfflineEvent> Function(OfflineEventDraft draft, int hubEpoch);
typedef VenueHubEventValidator =
    Future<Map<String, Object?>> Function(
      String eventType,
      Map<String, Object?> payload,
      VenueHubStaffGrant grant,
    );

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
    VenueHubEventValidator? validateEvent,
    VenueHubReplayGuard? replayGuard,
  }) : credentials = Map<String, VenueHubPublicCredential>.from(credentials),
       _authorizeStaff = authorizeStaff,
       _commitEvent = commitEvent,
       _validateEvent = validateEvent ?? _identityValidator,
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
  final VenueHubEventValidator _validateEvent;
  final VenueHubReplayGuard _replayGuard;

  static const _permissionByEvent = <String, String>{
    'order.opened': 'order',
    'order.itemAdded': 'order',
    'order.itemQuantityChanged': 'order',
    'order.sent': 'order',
    'payment.recorded': 'payment',
    'order.closed': 'payment',
    'receipt.requested': 'order',
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
    final rawEventType = body['eventType'];
    final eventType = rawEventType is String ? rawEventType : null;
    final permission = eventType == null ? null : _permissionByEvent[eventType];
    if (eventType == null || permission == null) {
      throw const VenueHubCommandException(
        'The staff member cannot perform this offline operation.',
      );
    }
    final grant = await authenticate(
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
    final canonicalPayload = await _validateEvent(
      eventType,
      Map<String, Object?>.from(rawPayload),
      grant,
    );
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
        type: eventType,
        payload: canonicalPayload,
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

  static Future<Map<String, Object?>> _identityValidator(
    String _,
    Map<String, Object?> payload,
    VenueHubStaffGrant _,
  ) async => payload;

  void installCredentials(
    Map<String, VenueHubPublicCredential> currentCredentials,
  ) {
    credentials
      ..clear()
      ..addAll(currentCredentials);
  }

  Future<VenueHubStaffGrant> authenticate({
    required VenueHubRequestEnvelope envelope,
    required Map<String, Object?> body,
    required DateTime trustedNowUtc,
    required String requiredPermission,
  }) async {
    await authenticateDevice(
      envelope: envelope,
      body: body,
      trustedNowUtc: trustedNowUtc,
    );
    final sessionId = body['staffSessionId'];
    final sessionToken = body['staffSessionToken'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        sessionId.length > 160 ||
        sessionToken is! String ||
        sessionToken.length < 32 ||
        sessionToken.length > 256) {
      throw const VenueHubCommandException(
        'A valid local staff session is required.',
      );
    }
    final grant = await _authorizeStaff(
      envelope.staffId,
      sessionId,
      sessionToken,
    );
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

  Future<void> authenticateDevice({
    required VenueHubRequestEnvelope envelope,
    required Map<String, Object?> body,
    required DateTime trustedNowUtc,
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
  }
}

class VenueHubCommandException implements Exception {
  const VenueHubCommandException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubCommandException: $message';
}
