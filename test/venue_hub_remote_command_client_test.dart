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
}
