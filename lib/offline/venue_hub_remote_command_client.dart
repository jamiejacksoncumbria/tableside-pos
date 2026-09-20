import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/tenant_scope.dart';
import 'venue_hub_client.dart';

typedef RemoteHubSubmitter = Future<Map<String, Object?>> Function(
  Map<String, Object?> request,
);

/// Global, process-local indicator used by the shell to make the durability
/// wait explicit. A remote command is never reported as saved merely because
/// Firebase accepted it; this remains active until the venue hub confirms its
/// own durable commit.
class RemoteHubWaitState {
  RemoteHubWaitState._();

  static final ValueNotifier<int> pending = ValueNotifier<int>(0);

  static void begin() => pending.value++;
  static void end() => pending.value = (pending.value - 1).clamp(0, 1 << 20);
}

class VenueHubRemoteCommandClient {
  VenueHubRemoteCommandClient({
    FirebaseFirestore? firestore,
    this.timeout = const Duration(seconds: 32),
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  final Duration timeout;

  Future<VenueHubEventAcknowledgement> send({
    required VenueScope scope,
    required int hubEpoch,
    required String eventType,
    required Map<String, Object?> payload,
    required RemoteHubSubmitter submit,
    DateTime? businessTimestampUtc,
  }) async {
    final commandId =
        'remote-${DateTime.now().microsecondsSinceEpoch}-${UniqueKey().hashCode.abs()}';
    RemoteHubWaitState.begin();
    try {
      final submitted = await submit(<String, Object?>{
        'tenantId': scope.tenantId,
        'venueId': scope.venueId,
        'hubEpoch': hubEpoch,
        'commandId': commandId,
        'idempotencyKey': commandId,
        'eventType': eventType,
        'payload': payload,
        if (businessTimestampUtc != null)
          'businessTimestampUtc': businessTimestampUtc.toUtc().toIso8601String(),
      });
      final returnedId = submitted['commandId'];
      if (returnedId is! String || returnedId != commandId) {
        throw StateError('The venue command server returned an invalid acknowledgement.');
      }
      final reference = _firestore
          .collection('tenants')
          .doc(scope.tenantId)
          .collection('venues')
          .doc(scope.venueId)
          .collection('remoteHubCommands')
          .doc(commandId);
      final snapshot = await reference.snapshots().firstWhere((value) {
        final status = value.data()?['status'];
        return status == 'accepted' || status == 'rejected' || status == 'expired';
      }).timeout(timeout);
      final value = snapshot.data();
      if (value == null) {
        throw StateError('The venue hub command disappeared before confirmation.');
      }
      if (value['status'] != 'accepted') {
        final message = value['rejectionMessage'];
        throw StateError(
          message is String && message.trim().isNotEmpty
              ? message
              : 'The venue hub did not accept this command in time.',
        );
      }
      final result = value['result'];
      if (result is! Map) {
        throw StateError('The venue hub returned an invalid durable acknowledgement.');
      }
      final data = Map<String, Object?>.from(result);
      final eventId = data['eventId'];
      final sequence = data['sequence'];
      final eventHash = data['eventHash'];
      final committedAt = DateTime.tryParse(data['committedAtUtc'] as String? ?? '');
      if (eventId is! String || sequence is! int || eventHash is! String || committedAt == null) {
        throw StateError('The venue hub returned an invalid durable acknowledgement.');
      }
      return VenueHubEventAcknowledgement(
        eventId: eventId,
        sequence: sequence,
        eventHash: eventHash,
        committedAtUtc: committedAt.toUtc(),
      );
    } on TimeoutException {
      throw StateError(
        'The venue hub did not confirm this command. It was not shown as saved; check the connection before retrying.',
      );
    } finally {
      RemoteHubWaitState.end();
    }
  }
}
