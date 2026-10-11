import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/tenant_scope.dart';
import '../core/app_busy_state.dart';
import 'venue_hub_client.dart';
import 'venue_hub_availability.dart';

typedef RemoteHubSubmitter =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef RemoteHubStatusWaiter =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

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
  VenueHubRemoteCommandClient({this.timeout = const Duration(seconds: 50)});

  final Duration timeout;

  Future<VenueHubEventAcknowledgement> send({
    required VenueScope scope,
    required int hubEpoch,
    required String eventType,
    required Map<String, Object?> payload,
    required RemoteHubSubmitter submit,
    required RemoteHubStatusWaiter waitForStatus,
    DateTime? businessTimestampUtc,
  }) async {
    return AppBusyState.guard(
      () => _sendUnblocked(
        scope: scope,
        hubEpoch: hubEpoch,
        eventType: eventType,
        payload: payload,
        submit: submit,
        waitForStatus: waitForStatus,
        businessTimestampUtc: businessTimestampUtc,
      ),
    );
  }

  Future<VenueHubEventAcknowledgement> _sendUnblocked({
    required VenueScope scope,
    required int hubEpoch,
    required String eventType,
    required Map<String, Object?> payload,
    required RemoteHubSubmitter submit,
    required RemoteHubStatusWaiter waitForStatus,
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
          'businessTimestampUtc': businessTimestampUtc
              .toUtc()
              .toIso8601String(),
      });
      final returnedId = submitted['commandId'];
      if (returnedId is! String || returnedId != commandId) {
        throw StateError(
          'The venue command server returned an invalid acknowledgement.',
        );
      }
      // Read the terminal state through the authenticated POS API rather than
      // a direct Firestore listener. This avoids platform cache/listener
      // differences while preserving the important invariant: only the
      // enrolled hub can move this document to `accepted`.
      final value = await waitForStatus(<String, Object?>{
        'tenantId': scope.tenantId,
        'venueId': scope.venueId,
        'commandId': commandId,
      }).timeout(timeout);
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
        throw StateError(
          'The venue hub returned an invalid durable acknowledgement.',
        );
      }
      final data = Map<String, Object?>.from(result);
      final eventId = data['eventId'];
      final sequence = data['sequence'];
      final eventHash = data['eventHash'];
      final committedAt = DateTime.tryParse(
        data['committedAtUtc'] as String? ?? '',
      );
      if (eventId is! String ||
          sequence is! int ||
          eventHash is! String ||
          committedAt == null) {
        throw StateError(
          'The venue hub returned an invalid durable acknowledgement.',
        );
      }
      VenueHubAvailability.markOnline();
      return VenueHubEventAcknowledgement(
        eventId: eventId,
        sequence: sequence,
        eventHash: eventHash,
        committedAtUtc: committedAt.toUtc(),
      );
    } on TimeoutException {
      VenueHubAvailability.markOffline();
      throw StateError(
        'The venue hub did not confirm this command. It was not shown as saved; check the connection before retrying.',
      );
    } on Object catch (error) {
      // Business-rule rejections (for example insufficient stock) prove that
      // the hub is online and responding. Only transport-shaped failures are
      // allowed to raise the global HUB OFFLINE warning.
      if (_looksLikeConnectivityFailure(error)) {
        VenueHubAvailability.markOffline(error.toString());
      }
      rethrow;
    } finally {
      RemoteHubWaitState.end();
    }
  }

  bool _looksLikeConnectivityFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('offline') ||
        message.contains('unavailable') ||
        message.contains('connection') ||
        message.contains('network') ||
        message.contains('socket') ||
        message.contains('timed out') ||
        message.contains('timeout');
  }
}
