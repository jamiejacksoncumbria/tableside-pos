import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_protocol.dart';

void main() {
  late KeyPair keyPair;
  final now = DateTime.utc(2026, 9, 12, 12);
  const body = <String, Object?>{
    'orderId': 'order-a',
    'line': {'quantity': 2, 'productId': 'product-a'},
  };

  setUp(() async {
    keyPair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index),
    );
  });

  Future<VenueHubRequestEnvelope> signed() =>
      VenueHubRequestSigner(keyPair).sign(
        credentialId: 'credential-a',
        tenantId: 'tenant-a',
        venueId: 'venue-a',
        deviceId: 'device-a',
        staffId: 'staff-a',
        method: 'POST',
        path: '/v1/orders/events',
        hubEpoch: 3,
        sentAtUtc: now,
        body: body,
        nonce: base64UrlEncode(List<int>.generate(24, (index) => index)),
      );

  test('accepts one valid authenticated venue request', () async {
    final envelope = await signed();
    final publicKey = await keyPair.extractPublicKey();
    await VenueHubReplayGuard().verify(
      envelope: envelope,
      body: body,
      credentialPublicKey: publicKey,
      expectedTenantId: 'tenant-a',
      expectedVenueId: 'venue-a',
      expectedHubEpoch: 3,
      trustedNowUtc: now.add(const Duration(seconds: 2)),
    );
  });

  test('rejects replay, modified payload and stale hub generation', () async {
    final envelope = await signed();
    final publicKey = await keyPair.extractPublicKey();
    final guard = VenueHubReplayGuard();
    await guard.verify(
      envelope: envelope,
      body: body,
      credentialPublicKey: publicKey,
      expectedTenantId: 'tenant-a',
      expectedVenueId: 'venue-a',
      expectedHubEpoch: 3,
      trustedNowUtc: now,
    );
    await expectLater(
      guard.verify(
        envelope: envelope,
        body: body,
        credentialPublicKey: publicKey,
        expectedTenantId: 'tenant-a',
        expectedVenueId: 'venue-a',
        expectedHubEpoch: 3,
        trustedNowUtc: now,
      ),
      throwsA(isA<VenueHubProtocolException>()),
    );

    await expectLater(
      VenueHubReplayGuard().verify(
        envelope: envelope,
        body: const {'orderId': 'order-b'},
        credentialPublicKey: publicKey,
        expectedTenantId: 'tenant-a',
        expectedVenueId: 'venue-a',
        expectedHubEpoch: 3,
        trustedNowUtc: now,
      ),
      throwsA(isA<VenueHubProtocolException>()),
    );
    await expectLater(
      VenueHubReplayGuard().verify(
        envelope: envelope,
        body: body,
        credentialPublicKey: publicKey,
        expectedTenantId: 'tenant-a',
        expectedVenueId: 'venue-a',
        expectedHubEpoch: 4,
        trustedNowUtc: now,
      ),
      throwsA(isA<VenueHubProtocolException>()),
    );
  });

  test('canonical signing is independent of map insertion order', () async {
    final signer = VenueHubRequestSigner(keyPair);
    final first = await signer.sign(
      credentialId: 'credential-a',
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
      staffId: 'staff-a',
      method: 'POST',
      path: '/v1/orders/events',
      hubEpoch: 3,
      sentAtUtc: now,
      body: const {'b': 2, 'a': 1},
      nonce: 'fixed-nonce',
    );
    final second = await signer.sign(
      credentialId: 'credential-a',
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'device-a',
      staffId: 'staff-a',
      method: 'POST',
      path: '/v1/orders/events',
      hubEpoch: 3,
      sentAtUtc: now,
      body: const {'a': 1, 'b': 2},
      nonce: 'fixed-nonce',
    );
    expect(first.signature, second.signature);
  });
}
