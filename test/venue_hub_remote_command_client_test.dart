import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/offline/venue_hub_remote_command_client.dart';

void main() {
  const scope = VenueScope(tenantId: 'tenant-a', venueId: 'venue-a');

  test('accepts only the hub-confirmed server acknowledgement', () async {
    String? submittedCommandId;
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 1),
    );

    final acknowledgement = await client.send(
      scope: scope,
      hubEpoch: 3,
      eventType: 'order.itemAdded',
      payload: const <String, Object?>{'orderId': 'order-a'},
      submit: (request) async {
        submittedCommandId = request['commandId'] as String;
        return <String, Object?>{'commandId': submittedCommandId};
      },
      waitForStatus: (request) async {
        expect(request['tenantId'], scope.tenantId);
        expect(request['venueId'], scope.venueId);
        expect(request['commandId'], submittedCommandId);
        return <String, Object?>{
          'commandId': submittedCommandId,
          'status': 'accepted',
          'result': <String, Object?>{
            'eventId': 'event-a',
            'sequence': 9,
            'eventHash': 'hash-a',
            'committedAtUtc': '2026-10-11T18:00:00.000Z',
          },
        };
      },
    );

    expect(acknowledgement.eventId, 'event-a');
    expect(acknowledgement.sequence, 9);
  });

  test('never treats a non-terminal server status as saved', () async {
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 1),
    );

    await expectLater(
      client.send(
        scope: scope,
        hubEpoch: 3,
        eventType: 'order.closed',
        payload: const <String, Object?>{'orderId': 'order-a'},
        submit: (request) async => <String, Object?>{
          'commandId': request['commandId'],
        },
        waitForStatus: (_) async => const <String, Object?>{
          'status': 'claimed',
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('surfaces a terminal hub rejection without retrying it', () async {
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 3),
    );
    var waits = 0;

    await expectLater(
      client.send(
        scope: scope,
        hubEpoch: 3,
        eventType: 'order.itemAdded',
        payload: const <String, Object?>{'orderId': 'order-a'},
        submit: (request) async => <String, Object?>{
          'commandId': request['commandId'],
        },
        waitForStatus: (_) async {
          waits++;
          return const <String, Object?>{
            'status': 'rejected',
            'stage': 'hubRejected',
            // "offline" previously caused this business rejection to be
            // mistaken for a broken network connection.
            'rejectionMessage':
                'An offline retry key was reused with different data.',
          };
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'An offline retry key was reused with different data.',
        ),
      ),
    );
    expect(waits, 1);
  });

  test('resumes the same command after an acknowledgement outage', () async {
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 3),
    );
    String? submittedCommandId;
    var waits = 0;

    final acknowledgement = await client.send(
      scope: scope,
      hubEpoch: 3,
      eventType: 'payment.recorded',
      payload: const <String, Object?>{
        'orderId': 'order-a',
        'paymentId': 'payment-a',
      },
      submit: (request) async {
        submittedCommandId = request['commandId'] as String;
        return <String, Object?>{'commandId': submittedCommandId};
      },
      waitForStatus: (request) async {
        expect(request['commandId'], submittedCommandId);
        waits++;
        if (waits == 1) {
          throw StateError('Network connection interrupted.');
        }
        return <String, Object?>{
          'commandId': submittedCommandId,
          'status': 'accepted',
          'stage': 'cloudProjected',
          'result': <String, Object?>{
            'eventId': 'event-payment-a',
            'sequence': 10,
            'eventHash': 'hash-payment-a',
            'committedAtUtc': '2026-10-12T10:00:00.000Z',
          },
        };
      },
    );

    expect(waits, 2);
    expect(acknowledgement.eventId, 'event-payment-a');
  });

  test('retries an ambiguous submission with one idempotency key', () async {
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 3),
    );
    final submittedIds = <String>[];
    var submissions = 0;

    await client.send(
      scope: scope,
      hubEpoch: 3,
      eventType: 'order.closed',
      payload: const <String, Object?>{'orderId': 'order-a'},
      submit: (request) async {
        submissions++;
        submittedIds.add(request['commandId'] as String);
        if (submissions == 1) {
          throw StateError('Connection closed before response.');
        }
        return <String, Object?>{'commandId': request['commandId']};
      },
      waitForStatus: (request) async => <String, Object?>{
        'commandId': request['commandId'],
        'status': 'accepted',
        'result': <String, Object?>{
          'eventId': 'event-close-a',
          'sequence': 11,
          'eventHash': 'hash-close-a',
          'committedAtUtc': '2026-10-12T10:01:00.000Z',
        },
      },
    );

    expect(submittedIds, hasLength(2));
    expect(submittedIds.toSet(), hasLength(1));
  });
}
