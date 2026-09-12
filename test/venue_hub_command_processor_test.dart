import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/venue_hub_bootstrap.dart';
import 'package:tableside_pos/offline/venue_hub_command_processor.dart';
import 'package:tableside_pos/offline/venue_hub_protocol.dart';

void main() {
  test('requires both device signature and active staff permission', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(List<int>.filled(32, 4));
    final publicKey = await keyPair.extractPublicKey();
    final committedDrafts = <OfflineEventDraft>[];
    final processor = VenueHubCommandProcessor(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      hubEpoch: 2,
      credentials: {
        'credential-a': VenueHubPublicCredential(
          id: 'credential-a',
          deviceId: 'device-a',
          publicKey: publicKey,
        ),
      },
      authorizeStaff: (staffId, sessionId, sessionToken) async =>
          VenueHubStaffGrant(
            staffId: staffId,
            permissions: const {'order'},
            expiresAtUtc: DateTime.utc(2026, 9, 12, 13),
            pinVersion: 1,
            membershipVersion: 1,
          ),
      commitEvent: (draft, epoch) async {
        committedDrafts.add(draft);
        return _event(draft, epoch);
      },
    );
    const body = <String, Object?>{
      'staffSessionId': 'session-a',
      'staffSessionToken': '01234567890123456789012345678901',
      'eventType': 'order.opened',
      'payload': {'orderId': 'order-a'},
    };
    final envelope = await VenueHubRequestSigner(keyPair).sign(
      credentialId: 'credential-a',
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
      staffId: 'staff-a',
      method: 'POST',
      path: '/v1/events',
      hubEpoch: 2,
      sentAtUtc: DateTime.utc(2026, 9, 12, 12),
      body: body,
      nonce: base64UrlEncode(List<int>.filled(24, 9)),
    );
    final acknowledgement = await processor.process(
      envelope: envelope,
      body: body,
      trustedNowUtc: DateTime.utc(2026, 9, 12, 12),
    );
    expect(acknowledgement.sequence, 1);
    expect(committedDrafts.single.type, 'order.opened');
    expect(committedDrafts.single.staffId, 'staff-a');
  });

  test('rejects payment without payment permission before commit', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(List<int>.filled(32, 5));
    final publicKey = await keyPair.extractPublicKey();
    var committed = false;
    final processor = VenueHubCommandProcessor(
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      hubEpoch: 2,
      credentials: {
        'credential-a': VenueHubPublicCredential(
          id: 'credential-a',
          deviceId: 'device-a',
          publicKey: publicKey,
        ),
      },
      authorizeStaff: (staffId, sessionId, sessionToken) async =>
          VenueHubStaffGrant(
            staffId: staffId,
            permissions: const {'order'},
            expiresAtUtc: DateTime.utc(2026, 9, 12, 13),
            pinVersion: 1,
            membershipVersion: 1,
          ),
      commitEvent: (draft, epoch) async {
        committed = true;
        return _event(draft, epoch);
      },
    );
    const body = <String, Object?>{
      'staffSessionId': 'session-a',
      'staffSessionToken': '01234567890123456789012345678901',
      'eventType': 'payment.recorded',
      'payload': {'orderId': 'order-a', 'baseAmountMinor': 100},
    };
    final envelope = await VenueHubRequestSigner(keyPair).sign(
      credentialId: 'credential-a',
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
      staffId: 'staff-a',
      method: 'POST',
      path: '/v1/events',
      hubEpoch: 2,
      sentAtUtc: DateTime.utc(2026, 9, 12, 12),
      body: body,
    );
    await expectLater(
      processor.process(
        envelope: envelope,
        body: body,
        trustedNowUtc: DateTime.utc(2026, 9, 12, 12),
      ),
      throwsA(isA<VenueHubCommandException>()),
    );
    expect(committed, isFalse);
  });
}

OfflineEvent _event(OfflineEventDraft draft, int epoch) {
  final now = DateTime.utc(2026, 9, 12, 12);
  return OfflineEvent(
    id: 'evt_test',
    tenantId: draft.tenantId,
    venueId: draft.venueId,
    deviceId: draft.deviceId,
    staffId: draft.staffId,
    type: draft.type,
    payload: draft.payload,
    createdAtUtc: now,
    deviceObservedAtUtc: now,
    timeAuthority: OfflineTimeAuthority.venueHub,
    clockSkewMillis: 0,
    businessTimestampUtc: now,
    sequence: 1,
    hubEpoch: epoch,
    previousHash: 'GENESIS',
    eventHash: 'hash',
    syncState: OfflineEventSyncState.pending,
  );
}
